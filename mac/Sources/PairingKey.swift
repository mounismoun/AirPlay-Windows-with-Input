import Foundation
import Security

struct KeychainError: Error {
    let status: OSStatus
}

struct PairingKey {
    let service: String
    init(service: String = "local.airplay-input.receiver.pairing") { self.service = service }

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "airplay-input-v1"]
    }

    static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return Data(bytes)
    }

    private func read() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let key = result as? Data, key.count == 16 else { throw KeychainError(status: errSecDecode) }
        return key
    }

    func loadOrCreate() throws -> Data {
        if let stored = try read() { return stored }
        let key = try Self.generate()
        var item = query
        item[kSecAttrLabel as String] = L10n.text("AirPlay Input pairing key")
        item[kSecValueData as String] = key
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let stored = try read() { return stored }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    func rotate() throws -> Data {
        let key = try Self.generate()
        let fields = [kSecValueData as String: key]
        let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }
}
