import CoreGraphics
import Foundation

// rdp_bridge.c 를 감싼다. 콜백은 RDP 스레드에서 오므로 메인 스레드로 넘겨 onEvent 를 부른다.
final class RdpConnection {
    enum Event {
        case connecting
        case connected
        case closed(errorName: String?)
    }

    struct Params {
        var host: String
        var port: UInt16
        var username: String
        var password: String
        var domain: String
        var width: UInt32
        var height: UInt32
        var desktopScale: UInt32
    }

    var onEvent: ((Event) -> Void)?
    private var session: OpaquePointer?

    func start(_ p: Params) -> Bool {
        // RDP 스레드가 CLOSED 를 알릴 때까지 이 객체가 살아 있어야 해서 그때까지 직접 붙잡는다.
        let retained = Unmanaged.passRetained(self)
        var callbacks = rdp_callbacks()
        callbacks.ctx = retained.toOpaque()
        callbacks.on_state = { ctx, state, errorName in
            guard let ctx else { return }
            let unmanaged = Unmanaged<RdpConnection>.fromOpaque(ctx)
            let connection = unmanaged.takeUnretainedValue()
            let event: Event
            switch state {
            case RDP_STATE_CONNECTING: event = .connecting
            case RDP_STATE_CONNECTED: event = .connected
            default: event = .closed(errorName: errorName.map { String(cString: $0) })
            }
            DispatchQueue.main.async { connection.onEvent?(event) }
            if state == RDP_STATE_CLOSED {
                unmanaged.release()
            }
        }

        let started: OpaquePointer? = p.host.withCString { host in
            p.username.withCString { username in
                p.password.withCString { password in
                    p.domain.withCString { domain -> OpaquePointer? in
                        var params = rdp_params(host: host, port: p.port, username: username,
                                                password: password, domain: domain, width: p.width,
                                                height: p.height, desktop_scale: p.desktopScale)
                        return rdp_session_start(&params, callbacks)
                    }
                }
            }
        }
        guard let started else {
            retained.release()
            return false
        }
        session = started
        return true
    }

    func stop() {
        guard let session else { return }
        rdp_session_stop(session)
    }

    deinit {
        guard let session else { return }
        rdp_session_release(session)
    }

    func mouseMove(_ p: (x: UInt16, y: UInt16)) {
        guard let session else { return }
        rdp_send_mouse_move(session, p.x, p.y)
    }

    func mouseButton(_ button: rdp_button, down: Bool, at p: (x: UInt16, y: UInt16)) {
        guard let session else { return }
        rdp_send_mouse_button(session, button, down, p.x, p.y)
    }

    func click(_ button: rdp_button, at p: (x: UInt16, y: UInt16)) {
        mouseMove(p)
        mouseButton(button, down: true, at: p)
        mouseButton(button, down: false, at: p)
    }

    func wheel(_ delta: Int32) {
        guard let session else { return }
        rdp_send_wheel(session, delta)
    }

    func key(_ key: rdp_key, down: Bool) {
        guard let session else { return }
        rdp_send_key(session, key, down)
    }

    func typeChar(_ unit: UInt16, asScancode: Bool) {
        guard let session else { return }
        rdp_type_char(session, unit, asScancode)
    }

    func requestResize(width: UInt32, height: UInt32, desktopScale: UInt32,
                       physicalWidthMM: UInt32, physicalHeightMM: UInt32) {
        guard let session else { return }
        rdp_request_resize(session, width, height, desktopScale, physicalWidthMM, physicalHeightMM)
    }

    // 마지막으로 읽은 뒤 바뀐 화면이 있으면 복사해 돌려준다.
    func copyFrameIfDirty() -> CGImage? {
        guard let session, rdp_frame_take_dirty(session) else { return nil }
        var frame = rdp_frame()
        guard rdp_frame_lock(session, &frame) else { return nil }
        defer { rdp_frame_unlock(session) }
        guard let base = frame.data,
              let data = CFDataCreate(nil, base, Int(frame.stride) * Int(frame.height)),
              let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: Int(frame.stride),
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    static func describe(errorName: String) -> String {
        switch errorName {
        case "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_AUTHENTICATION_FAILED", "ERRCONNECT_WRONG_PASSWORD":
            return "사용자 이름이나 비밀번호가 맞지 않습니다."
        case "ERRCONNECT_DNS_NAME_NOT_FOUND":
            return "PC 주소를 찾지 못했습니다."
        case "ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_CONNECT_TRANSPORT_FAILED":
            return "PC에 연결하지 못했습니다. 주소·포트와 네트워크를 확인해 주세요."
        case "ERRCONNECT_PASSWORD_EXPIRED", "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED",
             "ERRCONNECT_PASSWORD_MUST_CHANGE":
            return "비밀번호가 만료됐습니다. PC에서 비밀번호를 바꾼 뒤 다시 연결해 주세요."
        case "ERRCONNECT_ACCOUNT_LOCKED_OUT", "ERRCONNECT_ACCOUNT_DISABLED":
            return "계정이 잠겨 있거나 사용할 수 없습니다."
        case "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION":
            return "다른 곳에서 이 PC에 접속해 연결이 끊겼습니다."
        case "ERRINFO_LOGOFF_BY_USER", "ERRINFO_RPC_INITIATED_LOGOFF":
            return "로그아웃되어 연결이 끊겼습니다."
        case "ERRINFO_IDLE_TIMEOUT":
            return "오래 사용하지 않아 연결이 끊겼습니다."
        default:
            return "연결이 끊겼습니다. (\(errorName))"
        }
    }
}
