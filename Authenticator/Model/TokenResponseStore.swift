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
    static let appGroupIdentifier = AppIdentifier.appGroup
    /// Set in the app group's defaults when the request was canceled in the app.
    static let canceledByUserKey = "canceledByUser"

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

    /// The key in a request's notification under which the extension names it. The answer is filed under that name,
    /// so an answer the app finishes late, for a request the extension gave up on, is never taken for the next one's,
    /// which may come from another app.
    static let requestIDKey = "requestID"

    /// A new name for a request.
    static func newRequestID() -> String {
        UUID().uuidString
    }

    func write(_ data: Data, for kind: TokenResponseKind, requestID: String) throws {
        let url = try fileURL(for: kind, requestID: requestID)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func read(_ kind: TokenResponseKind, requestID: String) -> Data? {
        guard let url = try? fileURL(for: kind, requestID: requestID) else { return nil }
        return try? Data(contentsOf: url)
    }

    func removeAll() throws {
        try FileManager.default.removeItem(at: directoryURL)
    }

    /// Only a UUID names a request, so the name can't reach outside the directory.
    private func fileURL(for kind: TokenResponseKind, requestID: String) throws -> URL {
        guard let id = UUID(uuidString: requestID) else { throw CocoaError(.fileWriteInvalidFileName) }
        return directoryURL.appendingPathComponent("\(kind.rawValue)-\(id.uuidString)")
    }
}
