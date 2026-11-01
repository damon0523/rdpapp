import Foundation
import Security

struct ConnectionSettings: Codable, Equatable {
    var host = ""
    var port = 3389
    var username = ""
    var domain = ""
    // 원격 해상도 = 화면 포인트 × 이 배수. 클수록 선명하고 데이터가 많이 든다.
    var resolutionScale = 2.0
    // Windows 배율(%). 낮출수록 한 화면에 더 많이 보인다.
    var desktopScale = 150

    struct ResolutionOption: Hashable {
        let value: Double
        let label: String
    }

    static let resolutionOptions = [
        ResolutionOption(value: 1.0, label: "보통"),
        ResolutionOption(value: 2.0, label: "선명"),
        ResolutionOption(value: 3.0, label: "아주 선명"),
    ]
    static let desktopScaleOptions = [100, 125, 150, 175, 200, 225, 250, 300]
}

final class ConnectionStore: ObservableObject {
    @Published var settings: ConnectionSettings
    @Published var password: String

    private static let settingsKey = "connection"
    private static let keychainService = "rdpapp"
    private static let keychainAccount = "password"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            settings = saved
        } else {
            settings = ConnectionSettings()
        }
        password = Keychain.read(service: Self.keychainService, account: Self.keychainAccount) ?? ""
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        Keychain.write(password, service: Self.keychainService, account: Self.keychainAccount)
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
