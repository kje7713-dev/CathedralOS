import XCTest
@testable import CathedralOSApp

private final class CreditStateServiceAuthStub: AuthService {
    var authState: AuthState
    var currentAccessToken: String?
    var refreshedAccessToken: String?
    var shouldFailRefresh = false
    private(set) var refreshSessionCallCount = 0

    init(userID: String = "11111111-1111-1111-1111-111111111111", accessToken: String = "user-jwt-token") {
        self.authState = .signedIn(AuthUser(id: userID, email: "tester@example.com"))
        self.currentAccessToken = accessToken
    }

    func checkSession() async {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {
        refreshSessionCallCount += 1
        if shouldFailRefresh {
            throw AuthServiceError.sessionExpired
        }
        if let refreshedAccessToken {
            currentAccessToken = refreshedAccessToken
        }
    }
}

private final class CreditStateServiceURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class CreditStateServiceTests: XCTestCase {

    override func tearDown() {
        CreditStateServiceURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchCreditStateUsesAuthenticatedHeadersAndDecodesAdminFlag() async throws {
        let service = makeService()

        CreditStateServiceURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/functions/v1/get-credit-state")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
              "planName": "free",
              "isPro": false,
              "monthlyCreditAllowance": 10,
              "purchasedCreditBalance": 5,
              "availableCredits": 15,
              "isAdmin": true,
              "currentPeriodEnd": null,
              "recentLedger": []
            }
            """
            return (response, Data(body.utf8))
        }

        let state = try await service.fetchCreditState()
        XCTAssertEqual(state.availableCredits, 15)
        XCTAssertTrue(state.isAdmin)
    }

    func testGrantCreditsPostsExpectedPayloadAndDecodesUpdatedState() async throws {
        let service = makeService()

        CreditStateServiceURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/functions/v1/admin-grant-credits")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")

            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["targetUserID"] as? String, "11111111-1111-1111-1111-111111111111")
            XCTAssertEqual(payload["amount"] as? Int, 100)
            XCTAssertEqual(payload["reason"] as? String, "testflight_dev_grant")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let responseBody = """
            {
              "planName": "free",
              "isPro": false,
              "monthlyCreditAllowance": 10,
              "purchasedCreditBalance": 100,
              "availableCredits": 110,
              "isAdmin": true,
              "currentPeriodEnd": null,
              "recentLedger": []
            }
            """
            return (response, Data(responseBody.utf8))
        }

        let state = try await service.grantCredits(
            targetUserID: "11111111-1111-1111-1111-111111111111",
            amount: 100,
            reason: "testflight_dev_grant"
        )

        XCTAssertEqual(state.purchasedCreditBalance, 100)
        XCTAssertEqual(state.availableCredits, 110)
        XCTAssertTrue(state.isAdmin)
    }

    func testFetchCreditStateRetriesAfterExpiredJWTWithRefreshedToken() async throws {
        let auth = CreditStateServiceAuthStub(accessToken: "expired-token")
        auth.refreshedAccessToken = "fresh-token"
        let service = makeService(authService: auth)
        var requestCount = 0

        CreditStateServiceURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), ["Bearer", "expired-token"].joined(separator: " "))
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"code":"PGRST303","message":"JWT expired"}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), ["Bearer", "fresh-token"].joined(separator: " "))
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {
              "planName": "free",
              "isPro": false,
              "monthlyCreditAllowance": 10,
              "purchasedCreditBalance": 5,
              "availableCredits": 15,
              "isAdmin": true,
              "currentPeriodEnd": null,
              "recentLedger": []
            }
            """
            return (response, Data(body.utf8))
        }

        let state = try await service.fetchCreditState()
        XCTAssertEqual(state.availableCredits, 15)
        XCTAssertEqual(auth.refreshSessionCallCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    private func makeService(authService: CreditStateServiceAuthStub = CreditStateServiceAuthStub()) -> BackendCreditStateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreditStateServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return BackendCreditStateService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(
                projectURL: URL(string: "https://example.supabase.co")!,
                anonKey: "anon-key"
            )
        )
    }
}
