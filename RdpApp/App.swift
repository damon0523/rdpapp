import SwiftUI

@main
struct RdpApp: App {
    @StateObject private var store = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environmentObject(store)
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var showingRemote = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        !store.settings.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !store.settings.username.isEmpty
            && !store.password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("PC") {
                    TextField("주소 (IP 또는 이름)", text: $store.settings.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("포트", value: $store.settings.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                }
                Section("계정") {
                    TextField("사용자 이름", text: $store.settings.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("비밀번호", text: $store.password)
                        .textContentType(.password)
                    TextField("도메인 (없으면 비워 두세요)", text: $store.settings.domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("선명도", selection: $store.settings.resolutionScale) {
                        ForEach(ConnectionSettings.resolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("Windows 배율", selection: $store.settings.desktopScale) {
                        ForEach(ConnectionSettings.desktopScaleOptions, id: \.self) { scale in
                            Text("\(scale)%").tag(scale)
                        }
                    }
                } header: {
                    Text("화면")
                } footer: {
                    Text("원격 화면은 지금 이 화면 크기에 맞춰 열리고, 접거나 펴면 다시 맞춰집니다. Windows 배율을 낮추면 한 화면에 더 많이 보입니다. 접속 중에는 화면 위 메뉴의 글자 크게·작게로 바꿀 수 있습니다.")
                }
                Section {
                    Button("연결") {
                        store.save()
                        showingRemote = true
                    }
                    .disabled(!canConnect)
                }
            }
            .navigationTitle("원격 PC")
        }
        .fullScreenCover(isPresented: $showingRemote) {
            RemoteScreen(store: store) { error in
                showingRemote = false
                errorMessage = error
            }
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
        }
        .alert("연결 알림", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct RemoteScreen: UIViewControllerRepresentable {
    let store: ConnectionStore
    let onClose: (String?) -> Void

    func makeUIViewController(context: Context) -> RemoteViewController {
        let controller = RemoteViewController(store: store)
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ controller: RemoteViewController, context: Context) {}
}
