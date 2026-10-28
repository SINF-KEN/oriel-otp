import Foundation
import Testing

@testable import Authenticator

// A separate protocol keeps these state-machine tests independent of the existing sync-test mock.
nonisolated final class EnteLoginURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recordedRequest = request
        if let body = Self.bodyData(from: request.httpBodyStream) {
            recordedRequest.httpBodyStream = nil
            recordedRequest.httpBody = body
        }
        Self.requests.append(recordedRequest)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { buffer in
                stream.read(buffer.baseAddress!, maxLength: buffer.count)
            }
            guard count >= 0 else { return nil }
            guard count > 0 else { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    static func makeAPI() throws -> EnteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnteLoginURLProtocol.self]
        return try EnteAPIClient(server: URL(string: "https://ente.test")!, session: URLSession(configuration: configuration))
    }
}

nonisolated enum EnteLoginTestData {
    static func emailMFAAttributes() -> [String: Any] {
        [
            "srpUserID": "id",
            "srpSalt": "AA==",
            "memLimit": 1,
            "opsLimit": 1,
            "kekSalt": "AA==",
            "isEmailMFAEnabled": true
        ]
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

@Suite(.serialized)
struct EnteLoginFlowTests {

    private func startEmailMFAFlow(verificationStatus: Int) async throws -> EnteLoginFlow {
        EnteLoginURLProtocol.requests = []
        EnteLoginURLProtocol.handler = { request in
            switch request.url?.path {
            case "/users/srp/attributes":
                return (200, try! JSONSerialization.data(withJSONObject: ["attributes": EnteLoginTestData.emailMFAAttributes()]))
            case "/users/ott":
                return (200, Data("{}".utf8))
            case "/users/verify-email":
                return (verificationStatus, Data())
            default:
                return (404, Data())
            }
        }

        let (flow, step) = try await EnteLoginFlow.start(api: EnteLoginURLProtocol.makeAPI(), email: "a@b.c")
        #expect(step == .emailCode)
        return flow
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test func emailCodeAndTOTPAdvanceThroughTheLoginFlow() async throws {
        EnteLoginURLProtocol.requests = []
        EnteLoginURLProtocol.handler = { request in
            switch request.url?.path {
            case "/users/srp/attributes":
                return (200, try! JSONSerialization.data(withJSONObject: ["attributes": EnteLoginTestData.emailMFAAttributes()]))
            case "/users/ott":
                return (200, Data("{}".utf8))
            case "/users/verify-email":
                return (200, EnteLoginTestData.json(["id": 42, "twoFactorSessionID": "totp-session"]))
            case "/users/two-factor/verify":
                return (200, EnteLoginTestData.json(["id": 42]))
            default:
                return (404, Data())
            }
        }

        let (flow, initialStep) = try await EnteLoginFlow.start(api: EnteLoginURLProtocol.makeAPI(), email: "a@b.c")
        #expect(initialStep == .emailCode)
        #expect(try await flow.submitCode("123 456") == .secondFactor(totp: true, passkey: false))
        #expect(try await flow.submitCode("987 654") == .password)

        let requests = EnteLoginURLProtocol.requests
        let emailRequest = try #require(requests.first { $0.url?.path == "/users/verify-email" })
        #expect(try body(emailRequest)["ott"] == "123456")
        let totpRequest = try #require(requests.first { $0.url?.path == "/users/two-factor/verify" })
        #expect(try body(totpRequest) == ["sessionID": "totp-session", "code": "987654"])
    }

    @Test func emailCodeErrorsAreMappedToActionableLoginErrors() async throws {
        for (status, expected) in [
            (401, EnteLoginError.incorrectCode),
            (404, EnteLoginError.codeExpired),
            (410, EnteLoginError.codeExpired),
            (429, EnteLoginError.tooManyAttempts)
        ] {
            let flow = try await startEmailMFAFlow(verificationStatus: status)
            do {
                _ = try await flow.submitCode("123456")
                Issue.record("Expected HTTP \(status) to fail login")
            } catch let error as EnteLoginError {
                #expect(error == expected)
            } catch {
                Issue.record("HTTP \(status) produced unexpected error: \(error)")
            }
        }
    }

    @Test func passkeyURLAndPollingFollowTheSecondFactorState() async throws {
        EnteLoginURLProtocol.requests = []
        EnteLoginURLProtocol.handler = { request in
            switch request.url?.path {
            case "/users/srp/attributes":
                return (200, try! JSONSerialization.data(withJSONObject: ["attributes": EnteLoginTestData.emailMFAAttributes()]))
            case "/users/ott":
                return (200, Data("{}".utf8))
            case "/users/verify-email":
                return (
                    200,
                    EnteLoginTestData.json([
                        "id": 42,
                        "passkeySessionID": "session /+?",
                        "accountsUrl": "https://accounts.ente.test"
                    ])
                )
            case "/users/two-factor/passkeys/get-token":
                let calls = EnteLoginURLProtocol.requests.filter { $0.url?.path == request.url?.path }.count
                return calls == 1 ? (400, Data()) : (200, EnteLoginTestData.json(["id": 42]))
            default:
                return (404, Data())
            }
        }

        let (flow, _) = try await EnteLoginFlow.start(api: EnteLoginURLProtocol.makeAPI(), email: "a@b.c")
        #expect(try await flow.submitCode("email-code") == .secondFactor(totp: false, passkey: true))
        let passkeyURL = try #require(flow.passkeyURL)
        let components = try #require(URLComponents(url: passkeyURL, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.ente.test")
        #expect(components.path == "/passkeys/verify")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(
            query == [
                "clientPackage": EnteAPIClient.clientPackage,
                "passkeySessionID": "session /+?",
                "redirect": "orielotp://passkey"
            ])
        #expect(try await flow.checkPasskey() == nil)
        #expect(try await flow.checkPasskey() == .password)
        #expect(flow.passkeyURL == nil)
    }

    @Test func passkeyPollingMapsExpiredSessions() async throws {
        EnteLoginURLProtocol.requests = []
        EnteLoginURLProtocol.handler = { request in
            switch request.url?.path {
            case "/users/srp/attributes":
                return (200, try! JSONSerialization.data(withJSONObject: ["attributes": EnteLoginTestData.emailMFAAttributes()]))
            case "/users/ott":
                return (200, Data("{}".utf8))
            case "/users/verify-email":
                return (200, EnteLoginTestData.json(["id": 42, "passkeySessionID": "passkey-session"]))
            case "/users/two-factor/passkeys/get-token":
                return (410, Data())
            default:
                return (404, Data())
            }
        }

        let (flow, _) = try await EnteLoginFlow.start(api: EnteLoginURLProtocol.makeAPI(), email: "a@b.c")
        _ = try await flow.submitCode("email-code")
        await #expect(throws: EnteLoginError.sessionExpired) {
            try await flow.checkPasskey()
        }
    }
}

@Suite(.serialized)
struct TokenResponseStoreTests {

    @Test func appAndExtensionShareProtectedResponsesAndCleanup() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = TokenResponseStore(containerURL: container)
        let signature = Data([0x10, 0x20, 0x30])
        let plaintext = Data("decrypted payload".utf8)

        try store.write(signature, for: .signed)
        try store.write(plaintext, for: .decrypted)
        #expect(store.read(.signed) == signature)
        #expect(store.read(.decrypted) == plaintext)
        try store.removeAll()
        #expect(store.read(.signed) == nil)
        #expect(store.read(.decrypted) == nil)
    }

    @Test func tokenSessionPolicyAllowsImplementedOperationsOnly() {
        for operation in [
            TokenSessionOperation.readData,
            .signData,
            .decryptData
        ] {
            #expect(TokenSessionPolicy.supports(operation))
        }
        #expect(!TokenSessionPolicy.supports(.performKeyExchange))
        #expect(!TokenSessionPolicy.supports(.unsupported))
    }
}
