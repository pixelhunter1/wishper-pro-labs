import Foundation
import LocalAuthentication
import Security

struct KeychainService {
    private let service = "com.wishperpro.desktop"
    private let account = "openai-api-key"

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: nonInteractiveContext(),
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if requiresReauthorization(addStatus) {
                throw KeychainError.reauthorizationRequired
            }
            guard addStatus == errSecSuccess else {
                throw KeychainError.operationFailed(addStatus)
            }
            return
        }

        if requiresReauthorization(updateStatus) {
            throw KeychainError.reauthorizationRequired
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainError.operationFailed(updateStatus)
        }
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: nonInteractiveContext(),
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if requiresReauthorization(status) {
            return nil
        }
        guard status == errSecSuccess else {
            return nil
        }

        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: nonInteractiveContext(),
        ]

        let status = SecItemDelete(query as CFDictionary)
        if requiresReauthorization(status) {
            throw KeychainError.reauthorizationRequired
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    private func requiresReauthorization(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    private func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

private enum KeychainError: LocalizedError {
    case operationFailed(OSStatus)
    case reauthorizationRequired

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            return "Falha ao aceder ao Keychain (código \(status))."
        case .reauthorizationRequired:
            return """
            O macOS bloqueou o acesso à key antiga após atualização da app.
            Remove a entrada 'com.wishperpro.desktop' no Keychain Access e guarda a API key novamente.
            """
        }
    }
}
