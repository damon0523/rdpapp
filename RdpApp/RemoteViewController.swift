import UIKit

// 원격 화면. 원격 해상도를 이 화면의 실제 크기에 맞춰 요청하고, 크기가 바뀌면(회전·접기·펴기) 다시 요청한다.
// 기기별 크기 상수는 두지 않는다 — 모든 크기는 뷰의 bounds 에서 나온다.
final class RemoteViewController: UIViewController {
    var onClose: ((String?) -> Void)?

    private struct Layout: Equatable {
        var width: UInt32
        var height: UInt32
        var desktopScale: UInt32
    }

    private let store: ConnectionStore
    private let connection = RdpConnection()
    private let displayView = RemoteDisplayView()
    private let keyField = KeyInputField()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let toast = UIButton(configuration: .filled())
    private let menuButton = UIButton(configuration: .filled())
    private var ctrlButton: UIButton?
    private var altButton: UIButton?

    private var displayLink: CADisplayLink?
    private var started = false
    private var connected = false
    private var closing = false
    private var sentLayout: Layout?
    private var resizeTimer: Timer?
    private var wheelRemainder: CGFloat = 0
    private var lastTap: (time: TimeInterval, location: CGPoint, remote: (x: UInt16, y: UInt16))?
    private var ctrlOn = false { didSet { updateModifierButtons() } }
    private var altOn = false { didSet { updateModifierButtons() } }

    init(store: ConnectionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 넓게 보이도록 안전 영역 밖(모서리·카메라 주변)까지 원격 화면으로 쓴다.
        displayView.frame = view.bounds
        displayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(displayView)

        keyField.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyField.alpha = 0.01
        keyField.onText = { [weak self] in self?.typeText($0) }
        keyField.onBackspace = { [weak self] in self?.tapKey(RDP_KEY_BACKSPACE) }
        keyField.onReturn = { [weak self] in self?.tapKey(RDP_KEY_RETURN) }
        keyField.inputAccessoryView = makeKeyBar()
        view.addSubview(keyField)

        statusLabel.text = "연결 중입니다…"
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        spinner.color = .white
        spinner.startAnimating()
        let status = UIStackView(arrangedSubviews: [spinner, statusLabel])
        status.axis = .vertical
        status.spacing = 12
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        toast.isUserInteractionEnabled = false
        toast.configuration?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        toast.configuration?.baseForegroundColor = .white
        toast.configuration?.cornerStyle = .capsule
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)

        menuButton.configuration?.image = UIImage(systemName: "ellipsis")
        menuButton.configuration?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        menuButton.configuration?.baseForegroundColor = .white
        menuButton.configuration?.cornerStyle = .capsule
        menuButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        menuButton.menu = makeMenu()
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            menuButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            menuButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            toast.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toast.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 12),
        ])

        addGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = displayView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if started {
            scheduleResize()
        } else {
            started = true
            startConnection(size: size)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    // MARK: - 연결

    private func startConnection(size: CGSize) {
        let layout = desiredLayout(for: size)
        sentLayout = layout
        connection.onEvent = { [weak self] in self?.handle($0) }

        let s = store.settings
        let params = RdpConnection.Params(
            host: s.host.trimmingCharacters(in: .whitespaces),
            port: UInt16(clamping: s.port),
            username: s.username,
            password: store.password,
            domain: s.domain,
            width: layout.width,
            height: layout.height,
            desktopScale: layout.desktopScale)
        guard connection.start(params) else {
            finish(error: "연결을 시작하지 못했습니다. 입력한 값을 확인해 주세요.")
            return
        }

        // 바뀔 때마다 화면 전체를 복사하므로, 큰 화면·높은 선명도에서도 버겁지 않게 초당 30번으로 묶는다.
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func handle(_ event: RdpConnection.Event) {
        switch event {
        case .connecting:
            statusLabel.text = "연결 중입니다…"
        case .connected:
            connected = true
            spinner.stopAnimating()
            statusLabel.superview?.isHidden = true
            sendResizeIfNeeded()
        case .closed(let errorName):
            finish(error: errorName.map(RdpConnection.describe(errorName:)))
        }
    }

    private func finish(error: String?) {
        guard !closing else { return }
        closing = true
        teardown()
        keyField.resignFirstResponder()
        onClose?(error)
    }

    private func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        resizeTimer?.invalidate()
        resizeTimer = nil
        connection.stop()
    }

    @objc private func tick() {
        if let image = connection.copyFrameIfDirty() {
            displayView.image = image
        }
    }

    // MARK: - 화면 크기

    private func desiredLayout(for size: CGSize) -> Layout {
        let s = store.settings
        let width = UInt32(min(max((size.width * s.resolutionScale).rounded(), 200), 8192)) & ~1
        let height = UInt32(min(max((size.height * s.resolutionScale).rounded(), 200), 8192))
        return Layout(width: width, height: height, desktopScale: UInt32(s.desktopScale))
    }

    // 회전·접기 중에는 크기가 여러 번 바뀌므로 멈춘 뒤 한 번만 보낸다.
    private func scheduleResize() {
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.sendResizeIfNeeded()
        }
    }

    private func sendResizeIfNeeded() {
        guard connected, !closing else { return }
        let size = displayView.bounds.size
        let layout = desiredLayout(for: size)
        guard layout != sentLayout else { return }
        sentLayout = layout
        connection.requestResize(width: layout.width, height: layout.height,
                                 desktopScale: layout.desktopScale,
                                 physicalWidthMM: Self.millimeters(size.width),
                                 physicalHeightMM: Self.millimeters(size.height))
    }

    // 아이폰은 대략 1인치에 160포인트. Windows 는 10mm 미만·10m 초과 값을 무시한다.
    private static func millimeters(_ points: CGFloat) -> UInt32 {
        UInt32(min(max(points / 160 * 25.4, 10), 10000))
    }

    private func changeDesktopScale(by step: Int) {
        let options = ConnectionSettings.desktopScaleOptions
        let index = options.firstIndex(of: store.settings.desktopScale) ?? options.firstIndex(of: 150) ?? 0
        let next = options[min(max(index + step, 0), options.count - 1)]
        store.settings.desktopScale = next
        store.save()
        sendResizeIfNeeded()
        showToast("Windows 배율 \(next)%")
    }

    private func showToast(_ text: String) {
        toast.configuration?.title = text
        toast.layer.removeAllAnimations()
        toast.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 1.2, options: [.beginFromCurrentState]) {
            self.toast.alpha = 0
        }
    }

    // MARK: - 메뉴

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "키보드", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.toggleKeyboard()
            },
            UIAction(title: "글자 크게", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in
                self?.changeDesktopScale(by: 1)
            },
            UIAction(title: "글자 작게", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in
                self?.changeDesktopScale(by: -1)
            },
            UIAction(title: "시작 메뉴", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                self?.tapKey(RDP_KEY_WIN)
            },
            UIAction(title: "연결 끊기", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                self?.connection.stop()
            },
        ])
    }

    private func toggleKeyboard() {
        if keyField.isFirstResponder {
            keyField.resignFirstResponder()
        } else {
            keyField.becomeFirstResponder()
        }
    }

    // MARK: - 터치

    private func addGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        [tap, longPress, drag, scroll].forEach(displayView.addGestureRecognizer)
    }

    // 손가락은 몇 포인트씩 흔들려 두 번 탭이 Windows 더블클릭 범위를 벗어난다. 연달아 가까이 탭하면 같은 점을 누른다.
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let location = g.location(in: displayView)
        guard var remote = displayView.remotePoint(location) else { return }
        let now = CACurrentMediaTime()
        if let last = lastTap, now - last.time < 0.5,
           hypot(location.x - last.location.x, location.y - last.location.y) < 20 {
            remote = last.remote
        }
        lastTap = (now, location, remote)
        connection.click(RDP_BUTTON_LEFT, at: remote)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let remote = displayView.remotePoint(g.location(in: displayView)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        connection.click(RDP_BUTTON_RIGHT, at: remote)
    }

    // 한 손가락으로 끌면 왼쪽 버튼을 누른 채 움직인다(창 옮기기·글자 선택).
    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: displayView)
        switch g.state {
        case .began:
            let translation = g.translation(in: displayView)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            guard let from = displayView.remotePoint(start) else { return }
            connection.mouseMove(from)
            connection.mouseButton(RDP_BUTTON_LEFT, down: true, at: from)
            if let to = displayView.remotePoint(location) { connection.mouseMove(to) }
        case .changed:
            if let to = displayView.remotePoint(location) { connection.mouseMove(to) }
        case .ended, .cancelled, .failed:
            if let to = displayView.remotePoint(location) {
                connection.mouseButton(RDP_BUTTON_LEFT, down: false, at: to)
            }
        default:
            break
        }
    }

    // 두 손가락으로 끌면 휠. 손가락을 내리면 위로 올라간다(아이폰 스크롤과 같은 방향). 약 30포인트가 휠 한 칸(120).
    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            wheelRemainder = 0
            if let remote = displayView.remotePoint(g.location(in: displayView)) { connection.mouseMove(remote) }
        case .changed:
            wheelRemainder += g.translation(in: displayView).y * 4
            g.setTranslation(.zero, in: displayView)
            var units = Int32(wheelRemainder)
            wheelRemainder -= CGFloat(units)
            while units != 0 {
                let step = max(min(units, 240), -240)
                connection.wheel(step)
                units -= step
            }
        default:
            break
        }
    }

    // MARK: - 키보드

    private func tapKey(_ key: rdp_key) {
        withModifiers {
            connection.key(key, down: true)
            connection.key(key, down: false)
        }
    }

    private func typeText(_ text: String) {
        let modified = ctrlOn || altOn
        withModifiers {
            for unit in text.utf16 {
                if unit == 10 {
                    connection.key(RDP_KEY_RETURN, down: true)
                    connection.key(RDP_KEY_RETURN, down: false)
                } else {
                    connection.typeChar(unit, asScancode: modified)
                }
            }
        }
    }

    // Ctrl·Alt 는 한 번 누르면 다음 키 하나에만 붙는다.
    private func withModifiers(_ body: () -> Void) {
        let ctrl = ctrlOn
        let alt = altOn
        if ctrl { connection.key(RDP_KEY_CTRL, down: true) }
        if alt { connection.key(RDP_KEY_ALT, down: true) }
        body()
        if alt { connection.key(RDP_KEY_ALT, down: false) }
        if ctrl { connection.key(RDP_KEY_CTRL, down: false) }
        ctrlOn = false
        altOn = false
    }

    private func makeKeyBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)

        let ctrl = barButton("Ctrl") { [weak self] in self?.ctrlOn.toggle() }
        let alt = barButton("Alt") { [weak self] in self?.altOn.toggle() }
        ctrlButton = ctrl
        altButton = alt
        let keys: [(String, rdp_key)] = [
            ("Esc", RDP_KEY_ESCAPE), ("Tab", RDP_KEY_TAB), ("Win", RDP_KEY_WIN),
            ("←", RDP_KEY_LEFT), ("↑", RDP_KEY_UP), ("↓", RDP_KEY_DOWN), ("→", RDP_KEY_RIGHT),
            ("Del", RDP_KEY_DELETE), ("Home", RDP_KEY_HOME), ("End", RDP_KEY_END),
            ("PgUp", RDP_KEY_PAGE_UP), ("PgDn", RDP_KEY_PAGE_DOWN),
        ]
        var buttons = keys.map { title, key in barButton(title) { [weak self] in self?.tapKey(key) } }
        buttons.insert(contentsOf: [ctrl, alt], at: 2)
        buttons.append(barButton(nil, image: "keyboard.chevron.compact.down") { [weak self] in
            self?.keyField.resignFirstResponder()
        })

        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return bar
    }

    private func barButton(_ title: String?, image: String? = nil, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = image.flatMap { UIImage(systemName: $0) }
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }

    private func updateModifierButtons() {
        for (button, on) in [(ctrlButton, ctrlOn), (altButton, altOn)] {
            guard let button else { continue }
            var config: UIButton.Configuration = on ? .filled() : .gray()
            config.title = button.configuration?.title
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            button.configuration = config
        }
    }
}

// 원격 화면을 비율을 지켜 꽉 채워 그린다. 원격 해상도를 이 뷰 크기에 맞춰 요청하므로 보통 빈 띠 없이 찬다.
final class RemoteDisplayView: UIView {
    var image: CGImage? {
        didSet { layer.contents = image }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func remotePoint(_ point: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard let image, bounds.width > 0, bounds.height > 0 else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(bounds.width / width, bounds.height / height)
        let origin = CGPoint(x: (bounds.width - width * scale) / 2, y: (bounds.height - height * scale) / 2)
        let x = min(max((point.x - origin.x) / scale, 0), width - 1)
        let y = min(max((point.y - origin.y) / scale, 0), height - 1)
        return (UInt16(x), UInt16(y))
    }
}

// 화면에 보이지 않는 입력칸. 한글은 조합이 끝나 확정된 글자만 보낸다 — 조합 중인 글자를 보내면 자모가 따로 찍힌다.
final class KeyInputField: UITextField, UITextFieldDelegate {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onReturn: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        tintColor = .clear
        delegate = self
        addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func textChanged() {
        guard markedTextRange == nil else { return }
        flush()
    }

    private func flush() {
        guard let value = text, !value.isEmpty else { return }
        text = ""
        onText?(value)
    }

    override func deleteBackward() {
        if text?.isEmpty ?? true {
            onBackspace?()
        } else {
            super.deleteBackward()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        unmarkText()
        flush()
        onReturn?()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        unmarkText()
        flush()
    }
}
