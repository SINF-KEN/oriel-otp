import Foundation

/// The response files shared by the app and its CryptoTokenKit extension.
nonisolated enum TokenResponseKind: String, Sendable {
    case signed = "signedData"
    case decrypted = "decryptedData"
}

nonisolated enum TokenSessionOperation: Sendable {
    case readData
    case signData
    case decryptData
    case performKeyExchange
    case unsupported
}

/// Small shared policies keep the app and extension in agreement about their file handoff and supported actions.
nonisolated enum TokenSessionPolicy {
    static let appGroupIdentifier = "group.io.github.sinf-ken.OrielOTP"

    static func supports(_ operation: TokenSessionOperation) -> Bool {
        switch operation {
        case .readData, .signData, .decryptData:
            true
        case .performKeyExchange, .unsupported:
            false
        }
    }
}

/// Stores private-key operation responses in the protected shared app-group container.
nonisolated struct TokenResponseStore: Sendable {
    static let directoryName = "TokenResponses"

    let directoryURL: URL

    init(containerURL: URL) {
        directoryURL = containerURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func write(_ data: Data, for kind: TokenResponseKind) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: kind), options: [.atomic, .completeFileProtection])
    }

    func read(_ kind: TokenResponseKind) -> Data? {
        try? Data(contentsOf: fileURL(for: kind))
    }

    func removeAll() throws {
        try FileManager.default.removeItem(at: directoryURL)
    }

    private func fileURL(for kind: TokenResponseKind) -> URL {
        directoryURL.appendingPathComponent(kind.rawValue)
    }
}
