#include "rdp_bridge.h"

#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/handle.h>
#include <winpr/synch.h>

#include <freerdp/channels/disp.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>

// 입력은 UI 스레드에서 들어오지만 FreeRDP 호출은 RDP 스레드 한 곳에서만 한다(upstream iOS 클라이언트와 같은 방식).
// UI 스레드는 큐에 넣고 이벤트를 울리기만 하고, RDP 스레드가 대기 루프에서 꺼내 보낸다.
#define QUEUE_CAP 512

// 디스플레이 제어(MS-RDPEDISP)가 받는 범위. 너비는 짝수여야 한다.
#define DISP_MIN_SIZE 200
#define DISP_MAX_SIZE 8192

typedef enum {
    EV_MOUSE,
    EV_KEY,
    EV_UNICODE,
    EV_RESIZE,
} ev_type;

typedef struct {
    ev_type type;
    uint16_t flags; // EV_MOUSE: PTR_FLAGS_*
    uint16_t x;
    uint16_t y;
    uint32_t code; // EV_KEY: RDP 스캔코드, EV_UNICODE: UTF-16 코드 단위
    bool down;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout; // EV_RESIZE
} rdp_event;

struct rdp_session {
    atomic_int refs;
    rdp_callbacks cb;
    freerdp* instance;

    pthread_mutex_t mtx; // queue · closed · stop_requested · last_x/y
    HANDLE queue_event;
    rdp_event queue[QUEUE_CAP];
    size_t queue_len;
    rdp_event work[QUEUE_CAP]; // RDP 스레드 전용 — 큐를 비울 때 옮겨 담는 곳
    bool closed;
    bool stop_requested;
    uint16_t last_x;
    uint16_t last_y;

    pthread_mutex_t frame_mtx; // gdi 버퍼 교체·해제와 UI 스레드의 화면 읽기를 가른다
    rdpGdi* gdi;
    atomic_bool dirty;

    pthread_mutex_t disp_mtx; // disp 콜백은 동적 채널 스레드에서도 불린다
    DispClientContext* disp;
    bool disp_ready;
    bool layout_pending;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
};

typedef struct {
    rdpClientContext common; // freerdp_client_OnChannelConnectedEventHandler 가 rdpClientContext 로 캐스트한다
    rdp_session* session;
} app_context;

static rdp_session* session_of(void* context) {
    return ((app_context*)context)->session;
}

#pragma mark - 큐

static void enqueue(rdp_session* s, rdp_event ev) {
    pthread_mutex_lock(&s->mtx);
    if (!s->closed) {
        const bool is_move = ev.type == EV_MOUSE && ev.flags == PTR_FLAGS_MOVE;
        const bool is_wheel = ev.type == EV_MOUSE && (ev.flags & PTR_FLAGS_WHEEL) != 0;
        if (is_wheel) {
            ev.x = s->last_x;
            ev.y = s->last_y;
        } else if (ev.type == EV_MOUSE) {
            s->last_x = ev.x;
            s->last_y = ev.y;
        }

        rdp_event* last = s->queue_len > 0 ? &s->queue[s->queue_len - 1] : NULL;
        if (is_move && last && last->type == EV_MOUSE && last->flags == PTR_FLAGS_MOVE)
            *last = ev; // 이어지는 이동은 마지막 위치만 보내면 된다
        else if (s->queue_len < QUEUE_CAP)
            s->queue[s->queue_len++] = ev;
        (void)SetEvent(s->queue_event);
    }
    pthread_mutex_unlock(&s->mtx);
}

// 서버가 DisplayControlCaps 를 보내기 전에는 레이아웃을 받지 않으므로 그때까지 쥐고 있다가 보낸다.
// 보내기는 RDP 스레드(drain_queue)에서만 한다.
static void send_pending_layout(rdp_session* s) {
    pthread_mutex_lock(&s->disp_mtx);
    if (s->disp && s->disp_ready && s->layout_pending && s->disp->SendMonitorLayout) {
        DISPLAY_CONTROL_MONITOR_LAYOUT layout = s->layout;
        if (s->disp->SendMonitorLayout(s->disp, 1, &layout) == CHANNEL_RC_OK)
            s->layout_pending = false;
    }
    pthread_mutex_unlock(&s->disp_mtx);
}

static void drain_queue(rdp_session* s, rdpContext* ctx) {
    pthread_mutex_lock(&s->mtx);
    const size_t n = s->queue_len;
    memcpy(s->work, s->queue, n * sizeof(rdp_event));
    s->queue_len = 0;
    (void)ResetEvent(s->queue_event);
    pthread_mutex_unlock(&s->mtx);

    rdpInput* input = ctx->input;
    for (size_t i = 0; i < n; i++) {
        const rdp_event* ev = &s->work[i];
        switch (ev->type) {
            case EV_MOUSE:
                (void)freerdp_input_send_mouse_event(input, ev->flags, ev->x, ev->y);
                break;
            case EV_KEY:
                (void)freerdp_input_send_keyboard_event_ex(input, ev->down, FALSE, ev->code);
                break;
            case EV_UNICODE:
                (void)freerdp_input_send_unicode_keyboard_event(input, ev->down ? 0 : KBD_FLAGS_RELEASE,
                                                                (UINT16)ev->code);
                break;
            case EV_RESIZE:
                pthread_mutex_lock(&s->disp_mtx);
                s->layout = ev->layout;
                s->layout_pending = true;
                pthread_mutex_unlock(&s->disp_mtx);
                break;
        }
    }
    send_pending_layout(s);
}

#pragma mark - 디스플레이 제어 채널

static UINT on_disp_caps(DispClientContext* disp, UINT32 max_monitors, UINT32 area_factor_a,
                         UINT32 area_factor_b) {
    (void)max_monitors;
    (void)area_factor_a;
    (void)area_factor_b;
    rdp_session* s = disp->custom;
    pthread_mutex_lock(&s->disp_mtx);
    s->disp_ready = true;
    pthread_mutex_unlock(&s->disp_mtx);
    (void)SetEvent(s->queue_event); // 쥐고 있던 레이아웃을 RDP 스레드가 보내도록 깨운다
    return CHANNEL_RC_OK;
}

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e) {
    freerdp_client_OnChannelConnectedEventHandler(context, e);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) != 0)
        return;

    rdp_session* s = session_of(context);
    DispClientContext* disp = e->pInterface;
    disp->custom = s;
    disp->DisplayControlCaps = on_disp_caps;
    pthread_mutex_lock(&s->disp_mtx);
    s->disp = disp;
    pthread_mutex_unlock(&s->disp_mtx);
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e) {
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        rdp_session* s = session_of(context);
        pthread_mutex_lock(&s->disp_mtx);
        s->disp = NULL;
        s->disp_ready = false;
        pthread_mutex_unlock(&s->disp_mtx);
    }
    freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

#pragma mark - 그리기

static BOOL on_begin_paint(rdpContext* ctx) {
    HGDI_WND hwnd = ctx->gdi->primary->hdc->hwnd;
    if (hwnd && hwnd->invalid) {
        hwnd->invalid->null = TRUE;
        hwnd->ninvalid = 0;
    }
    return TRUE;
}

// 바뀐 영역이 비었는지 따지지 않고 표시만 한다 — 화면을 한 번 더 복사하는 비용이 멈춘 화면보다 싸다.
static BOOL on_end_paint(rdpContext* ctx) {
    atomic_store(&session_of(ctx)->dirty, true);
    return TRUE;
}

static BOOL on_desktop_resize(rdpContext* ctx) {
    rdp_session* s = session_of(ctx);
    const UINT32 width = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopHeight);
    pthread_mutex_lock(&s->frame_mtx);
    const BOOL ok = gdi_resize(ctx->gdi, width, height);
    pthread_mutex_unlock(&s->frame_mtx);
    atomic_store(&s->dirty, true);
    return ok;
}

static void free_gdi(rdp_session* s, freerdp* instance) {
    pthread_mutex_lock(&s->frame_mtx);
    s->gdi = NULL;
    gdi_free(instance);
    pthread_mutex_unlock(&s->frame_mtx);
}

#pragma mark - 연결 콜백

static BOOL on_pre_connect(freerdp* instance) {
    rdpContext* ctx = instance->context;
    rdpSettings* settings = ctx->settings;

    const char* password = freerdp_settings_get_string(settings, FreeRDP_Password);
    if (!freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, password && password[0]))
        return FALSE;
    if (PubSub_SubscribeChannelConnected(ctx->pubSub, on_channel_connected) != CHANNEL_RC_OK)
        return FALSE;
    if (PubSub_SubscribeChannelDisconnected(ctx->pubSub, on_channel_disconnected) != CHANNEL_RC_OK)
        return FALSE;
    return freerdp_client_load_addins(ctx->channels, settings);
}

static BOOL on_post_connect(freerdp* instance) {
    rdpContext* ctx = instance->context;
    rdp_session* s = session_of(ctx);

    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
        return FALSE;
    pthread_mutex_lock(&s->frame_mtx);
    s->gdi = ctx->gdi;
    pthread_mutex_unlock(&s->frame_mtx);

    ctx->update->BeginPaint = on_begin_paint;
    ctx->update->EndPaint = on_end_paint;
    ctx->update->DesktopResize = on_desktop_resize;
    return TRUE;
}

static void on_post_disconnect(freerdp* instance) {
    free_gdi(session_of(instance->context), instance);
}

// 계정은 설정 화면에서 받아 /u /p 로 넘긴다. 그래도 물어 오면 빠진 것이므로 연결을 멈춘다.
static BOOL on_authenticate(freerdp* instance, char** username, char** password, char** domain,
                            rdp_auth_reason reason) {
    (void)instance;
    (void)domain;
    (void)reason;
    return *username && **username && *password && **password;
}

// 2 = 이번 연결에만 인증서를 받아들인다. 자기 PC 에 붙는 용도라 묻지 않는다.
static DWORD on_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                   const char* common_name, const char* subject, const char* issuer,
                                   const char* fingerprint, DWORD flags) {
    (void)instance;
    (void)host;
    (void)port;
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)fingerprint;
    (void)flags;
    return 2;
}

static DWORD on_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                           const char* common_name, const char* subject,
                                           const char* issuer, const char* new_fingerprint,
                                           const char* old_subject, const char* old_issuer,
                                           const char* old_fingerprint, DWORD flags) {
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    return on_verify_certificate(instance, host, port, common_name, subject, issuer, new_fingerprint,
                                 flags);
}

static BOOL client_new(freerdp* instance, rdpContext* context) {
    (void)context;
    instance->PreConnect = on_pre_connect;
    instance->PostConnect = on_post_connect;
    instance->PostDisconnect = on_post_disconnect;
    instance->AuthenticateEx = on_authenticate;
    instance->VerifyCertificateEx = on_verify_certificate;
    instance->VerifyChangedCertificateEx = on_verify_changed_certificate;
    return TRUE;
}

#pragma mark - 세션

static void* run_session(void* arg) {
    rdp_session* s = arg;
    freerdp* instance = s->instance;
    rdpContext* ctx = instance->context;

    s->cb.on_state(s->cb.ctx, RDP_STATE_CONNECTING, NULL);
    if (freerdp_connect(instance)) {
        s->cb.on_state(s->cb.ctx, RDP_STATE_CONNECTED, NULL);
        while (!freerdp_shall_disconnect_context(ctx)) {
            HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
            const DWORD n = freerdp_get_event_handles(ctx, handles, ARRAYSIZE(handles) - 1);
            if (n == 0)
                break;
            handles[n] = s->queue_event;
            if (WaitForMultipleObjects(n + 1, handles, FALSE, INFINITE) == WAIT_FAILED)
                break;
            if (!freerdp_check_event_handles(ctx))
                break;
            drain_queue(s, ctx);
        }
        (void)freerdp_disconnect(instance);
    }

    const UINT32 error = freerdp_get_last_error(ctx);
    pthread_mutex_lock(&s->mtx);
    const bool stopped = s->stop_requested;
    s->closed = true; // 이 뒤로 rdp_session_stop 은 ctx 를 건드리지 않는다
    pthread_mutex_unlock(&s->mtx);

    const char* error_name =
        (!stopped && error != FREERDP_ERROR_SUCCESS) ? freerdp_get_last_error_name(error) : NULL;
    free_gdi(s, instance);
    freerdp_client_context_free(ctx);
    s->cb.on_state(s->cb.ctx, RDP_STATE_CLOSED, error_name);
    rdp_session_release(s);
    return NULL;
}

static char* format_arg(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char* out = NULL;
    if (vasprintf(&out, fmt, ap) < 0)
        out = NULL;
    va_end(ap);
    return out;
}

// 채널(그래픽 파이프라인 · 디스플레이 제어)을 켜는 부수 설정까지 FreeRDP 가 맞춰 주도록 명령줄로 넘긴다.
static BOOL apply_params(rdpSettings* settings, const rdp_params* p) {
    char* argv[16] = { 0 };
    int argc = 0;
    argv[argc++] = strdup("rdpapp");
    argv[argc++] = format_arg("/v:%s", p->host);
    argv[argc++] = format_arg("/port:%u", (unsigned)p->port);
    argv[argc++] = format_arg("/u:%s", p->username);
    argv[argc++] = format_arg("/p:%s", p->password);
    if (p->domain && p->domain[0])
        argv[argc++] = format_arg("/d:%s", p->domain);
    argv[argc++] = format_arg("/size:%ux%u", p->width, p->height);
    argv[argc++] = format_arg("/scale-desktop:%u", p->desktop_scale);
    argv[argc++] = strdup("/gdi:sw");
    argv[argc++] = strdup("/gfx");
    argv[argc++] = strdup("/dynamic-resolution");
    argv[argc++] = strdup("/network:auto");
    argv[argc++] = strdup("-clipboard");
    argv[argc++] = strdup("/relax-order-checks");
    argv[argc++] = strdup("/log-level:INFO");

    BOOL ok = TRUE;
    for (int i = 0; i < argc; i++)
        if (!argv[i])
            ok = FALSE;
    if (ok)
        ok = freerdp_client_settings_parse_command_line(settings, argc, argv, FALSE) == 0;
    for (int i = 0; i < argc; i++)
        free(argv[i]);
    return ok;
}

static void ignore_sigpipe(void) {
    (void)signal(SIGPIPE, SIG_IGN);
}

void rdp_session_release(rdp_session* s) {
    if (!s || atomic_fetch_sub(&s->refs, 1) != 1)
        return;
    if (s->queue_event)
        (void)CloseHandle(s->queue_event);
    pthread_mutex_destroy(&s->mtx);
    pthread_mutex_destroy(&s->frame_mtx);
    pthread_mutex_destroy(&s->disp_mtx);
    free(s);
}

static bool start_thread(rdp_session* s) {
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0)
        return false;
    (void)pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
    (void)pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    const bool ok = pthread_create(&thread, &attr, run_session, s) == 0;
    pthread_attr_destroy(&attr);
    return ok;
}

rdp_session* rdp_session_start(const rdp_params* params, rdp_callbacks callbacks) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, ignore_sigpipe);

    rdp_session* s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    atomic_init(&s->refs, 1);
    atomic_init(&s->dirty, false);
    s->cb = callbacks;
    pthread_mutex_init(&s->mtx, NULL);
    pthread_mutex_init(&s->frame_mtx, NULL);
    pthread_mutex_init(&s->disp_mtx, NULL);

    s->queue_event = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!s->queue_event) {
        rdp_session_release(s);
        return NULL;
    }

    RDP_CLIENT_ENTRY_POINTS ep = { 0 };
    ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.ContextSize = sizeof(app_context);
    ep.ClientNew = client_new;
    rdpContext* ctx = freerdp_client_context_new(&ep);
    if (!ctx) {
        rdp_session_release(s);
        return NULL;
    }
    ((app_context*)ctx)->session = s;
    s->instance = ctx->instance;

    if (!apply_params(ctx->settings, params)) {
        freerdp_client_context_free(ctx);
        rdp_session_release(s);
        return NULL;
    }

    atomic_fetch_add(&s->refs, 1); // RDP 스레드 몫 — 스레드가 끝날 때 놓는다
    if (!start_thread(s)) {
        atomic_fetch_sub(&s->refs, 1);
        freerdp_client_context_free(ctx);
        rdp_session_release(s);
        return NULL;
    }
    return s;
}

void rdp_session_stop(rdp_session* s) {
    pthread_mutex_lock(&s->mtx);
    if (!s->closed) {
        s->stop_requested = true;
        (void)freerdp_abort_connect_context(s->instance->context);
    }
    pthread_mutex_unlock(&s->mtx);
}

#pragma mark - 입력

void rdp_send_mouse_move(rdp_session* s, uint16_t x, uint16_t y) {
    enqueue(s, (rdp_event){ .type = EV_MOUSE, .flags = PTR_FLAGS_MOVE, .x = x, .y = y });
}

void rdp_send_mouse_button(rdp_session* s, rdp_button button, bool down, uint16_t x, uint16_t y) {
    uint16_t flags = button == RDP_BUTTON_LEFT ? PTR_FLAGS_BUTTON1 : PTR_FLAGS_BUTTON2;
    if (down)
        flags |= PTR_FLAGS_DOWN;
    enqueue(s, (rdp_event){ .type = EV_MOUSE, .flags = flags, .x = x, .y = y });
}

// 휠 값은 9비트 부호 있는 수 — 하위 8비트에 2의 보수, 음수면 PTR_FLAGS_WHEEL_NEGATIVE.
void rdp_send_wheel(rdp_session* s, int32_t delta) {
    if (delta > 255)
        delta = 255;
    if (delta < -255)
        delta = -255;
    if (delta == 0)
        return;
    uint16_t flags = PTR_FLAGS_WHEEL;
    if (delta < 0)
        flags |= PTR_FLAGS_WHEEL_NEGATIVE | (uint16_t)((0x100 + delta) & 0xFF);
    else
        flags |= (uint16_t)delta;
    enqueue(s, (rdp_event){ .type = EV_MOUSE, .flags = flags });
}

static UINT32 scancode_for(rdp_key key) {
    switch (key) {
        case RDP_KEY_ESCAPE: return RDP_SCANCODE_ESCAPE;
        case RDP_KEY_TAB: return RDP_SCANCODE_TAB;
        case RDP_KEY_BACKSPACE: return RDP_SCANCODE_BACKSPACE;
        case RDP_KEY_RETURN: return RDP_SCANCODE_RETURN;
        case RDP_KEY_DELETE: return RDP_SCANCODE_DELETE;
        case RDP_KEY_CTRL: return RDP_SCANCODE_LCONTROL;
        case RDP_KEY_ALT: return RDP_SCANCODE_LMENU;
        case RDP_KEY_SHIFT: return RDP_SCANCODE_LSHIFT;
        case RDP_KEY_WIN: return RDP_SCANCODE_LWIN;
        case RDP_KEY_UP: return RDP_SCANCODE_UP;
        case RDP_KEY_DOWN: return RDP_SCANCODE_DOWN;
        case RDP_KEY_LEFT: return RDP_SCANCODE_LEFT;
        case RDP_KEY_RIGHT: return RDP_SCANCODE_RIGHT;
        case RDP_KEY_HOME: return RDP_SCANCODE_HOME;
        case RDP_KEY_END: return RDP_SCANCODE_END;
        case RDP_KEY_PAGE_UP: return RDP_SCANCODE_PRIOR;
        case RDP_KEY_PAGE_DOWN: return RDP_SCANCODE_NEXT;
    }
    return RDP_SCANCODE_UNKNOWN;
}

void rdp_send_key(rdp_session* s, rdp_key key, bool down) {
    enqueue(s, (rdp_event){ .type = EV_KEY, .code = scancode_for(key), .down = down });
}

// 미국 배열 기준 스캔코드. 유니코드 입력은 Ctrl·Alt 와 섞이지 않아 조합키일 때만 쓴다.
static UINT32 ascii_scancode(uint16_t c) {
    static const uint8_t letters[26] = { 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17,
                                         0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13,
                                         0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C };
    if (c >= 'a' && c <= 'z')
        return letters[c - 'a'];
    if (c >= 'A' && c <= 'Z')
        return letters[c - 'A'];
    if (c >= '1' && c <= '9')
        return 0x02 + (c - '1');
    if (c == '0')
        return 0x0B;
    if (c == ' ')
        return RDP_SCANCODE_SPACE;
    return RDP_SCANCODE_UNKNOWN;
}

void rdp_type_char(rdp_session* s, uint16_t utf16, bool as_scancode) {
    const UINT32 scancode = as_scancode ? ascii_scancode(utf16) : RDP_SCANCODE_UNKNOWN;
    if (scancode != RDP_SCANCODE_UNKNOWN) {
        enqueue(s, (rdp_event){ .type = EV_KEY, .code = scancode, .down = true });
        enqueue(s, (rdp_event){ .type = EV_KEY, .code = scancode, .down = false });
    } else {
        enqueue(s, (rdp_event){ .type = EV_UNICODE, .code = utf16, .down = true });
        enqueue(s, (rdp_event){ .type = EV_UNICODE, .code = utf16, .down = false });
    }
}

#pragma mark - 화면 크기

static uint32_t clamp_size(uint32_t v) {
    if (v < DISP_MIN_SIZE)
        return DISP_MIN_SIZE;
    if (v > DISP_MAX_SIZE)
        return DISP_MAX_SIZE;
    return v;
}

void rdp_request_resize(rdp_session* s, uint32_t width, uint32_t height, uint32_t desktop_scale,
                        uint32_t physical_width_mm, uint32_t physical_height_mm) {
    rdp_event ev = { .type = EV_RESIZE };
    ev.layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    ev.layout.Width = clamp_size(width) & ~1u;
    ev.layout.Height = clamp_size(height);
    ev.layout.PhysicalWidth = physical_width_mm;
    ev.layout.PhysicalHeight = physical_height_mm;
    ev.layout.Orientation = 0; // 가로·세로를 Width·Height 로 이미 맞춰 보내므로 회전은 늘 0
    ev.layout.DesktopScaleFactor = desktop_scale;
    ev.layout.DeviceScaleFactor = 100;
    enqueue(s, ev);
}

bool rdp_frame_take_dirty(rdp_session* s) {
    return atomic_exchange(&s->dirty, false);
}

bool rdp_frame_lock(rdp_session* s, rdp_frame* out) {
    pthread_mutex_lock(&s->frame_mtx);
    const rdpGdi* gdi = s->gdi;
    if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0) {
        pthread_mutex_unlock(&s->frame_mtx);
        return false;
    }
    out->data = gdi->primary_buffer;
    out->width = (uint32_t)gdi->width;
    out->height = (uint32_t)gdi->height;
    out->stride = gdi->stride;
    return true;
}

void rdp_frame_unlock(rdp_session* s) {
    pthread_mutex_unlock(&s->frame_mtx);
}
