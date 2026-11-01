#ifndef RDP_BRIDGE_H
#define RDP_BRIDGE_H

// Swift 가 보는 유일한 헤더. FreeRDP 헤더는 C23(nullptr 등)을 써서 Swift 로 넘기지 않고,
// 여기에는 표준 C 타입만 둔다. FreeRDP 는 rdp_bridge.c 안에서만 쓴다.

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    RDP_STATE_CONNECTING = 1,
    RDP_STATE_CONNECTED = 2,
    RDP_STATE_CLOSED = 3,
} rdp_state;

typedef enum {
    RDP_KEY_ESCAPE,
    RDP_KEY_TAB,
    RDP_KEY_BACKSPACE,
    RDP_KEY_RETURN,
    RDP_KEY_DELETE,
    RDP_KEY_CTRL,
    RDP_KEY_ALT,
    RDP_KEY_SHIFT,
    RDP_KEY_WIN,
    RDP_KEY_UP,
    RDP_KEY_DOWN,
    RDP_KEY_LEFT,
    RDP_KEY_RIGHT,
    RDP_KEY_HOME,
    RDP_KEY_END,
    RDP_KEY_PAGE_UP,
    RDP_KEY_PAGE_DOWN,
} rdp_key;

typedef enum {
    RDP_BUTTON_LEFT,
    RDP_BUTTON_RIGHT,
} rdp_button;

typedef struct {
    void* ctx;
    // RDP 스레드에서 불린다. RDP_STATE_CLOSED 가 마지막 호출이고, 그 뒤로는 ctx 를 쓰지 않는다.
    // error_name 은 FreeRDP 오류 이름(예: ERRCONNECT_LOGON_FAILURE), 오류가 없으면 NULL.
    void (*on_state)(void* ctx, rdp_state state, const char* error_name);
} rdp_callbacks;

typedef struct {
    const char* host;
    uint16_t port;
    const char* username;
    const char* password;
    const char* domain; // 빈 문자열이면 보내지 않는다
    uint32_t width;     // 원격 데스크톱 픽셀 크기
    uint32_t height;
    uint32_t desktop_scale; // Windows 배율(%)
} rdp_params;

typedef struct {
    const uint8_t* data; // 32bit BGRX, little-endian
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} rdp_frame;

typedef struct rdp_session rdp_session;

// 실패하면 NULL. 성공하면 호출자가 참조 하나를 가지며 rdp_session_release 로 놓는다.
rdp_session* rdp_session_start(const rdp_params* params, rdp_callbacks callbacks);
void rdp_session_stop(rdp_session* s);
void rdp_session_release(rdp_session* s);

void rdp_send_mouse_move(rdp_session* s, uint16_t x, uint16_t y);
void rdp_send_mouse_button(rdp_session* s, rdp_button button, bool down, uint16_t x, uint16_t y);
// delta 는 휠 단위(한 칸 = 120), 양수가 위로.
void rdp_send_wheel(rdp_session* s, int32_t delta);
void rdp_send_key(rdp_session* s, rdp_key key, bool down);
// 한 글자를 누르고 뗀다. as_scancode 이면 영문·숫자를 키 코드로 보낸다(Ctrl·Alt 조합용).
void rdp_type_char(rdp_session* s, uint16_t utf16, bool as_scancode);

// 화면 크기가 바뀌면 원격 해상도를 다시 요청한다. 서버가 디스플레이 제어를 지원할 때만 반영된다.
void rdp_request_resize(rdp_session* s, uint32_t width, uint32_t height, uint32_t desktop_scale,
                        uint32_t physical_width_mm, uint32_t physical_height_mm);

// 마지막으로 읽은 뒤 화면이 바뀌었으면 true 를 돌려주고 표시를 지운다.
bool rdp_frame_take_dirty(rdp_session* s);
// true 면 rdp_frame_unlock 전까지 out->data 를 읽을 수 있다.
bool rdp_frame_lock(rdp_session* s, rdp_frame* out);
void rdp_frame_unlock(rdp_session* s);

#endif
