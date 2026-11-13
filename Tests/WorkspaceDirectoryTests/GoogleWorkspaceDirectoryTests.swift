import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import WorkspaceDirectory

struct GoogleWorkspaceDirectoryTests {
    @Test func requestsOnlyFieldsAndScopesNeededForEligibility() async throws {
        let directory = GoogleWorkspaceDirectory(accessToken: { scope in
            switch scope {
            case .userReadOnly: "user-synthetic"
            case .groupMembershipReadOnly: "group-synthetic"
            }
        }) { request in
            let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            #expect(components.scheme == "https")
            #expect(components.host == "admin.googleapis.com")
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.timeoutInterval == 5)
            switch components.path {
            case "/admin/directory/v1/users/user-id":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-synthetic")
                #expect(components.queryItems == [
                    URLQueryItem(name: "viewType", value: "admin_view"),
                    URLQueryItem(name: "fields", value: "id,customerId,suspended,archived,isGuestUser,deletionTime"),
                ])
                return try reply(request, body: #"{"id":"user-id","customerId":"customer-id","suspended":false,"archived":false,"isGuestUser":false}"#)
            case "/admin/directory/v1/groups/group-id/hasMember/user-id":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer group-synthetic")
                #expect(components.query == nil)
                return try reply(request, body: #"{"isMember":true}"#)
            default:
                Issue.record("Unexpected request path")
                throw WorkspaceDirectoryFailure.unverifiable
            }
        }
        let verifier = WorkspaceEmployeeVerifier(directory: directory, customerID: "customer-id", groupID: "group-id")
        #expect(await verifier.verify(directoryUserID: "user-id") == .eligible)
    }

    @Test(arguments: [
        #"{"id":"other-id","customerId":"customer-id","suspended":false,"archived":false,"isGuestUser":false}"#,
        #"{"id":"user-id","customerId":"customer-id","suspended":false,"archived":false}"#,
        #"{"id":"user-id","customerId":"customer-id","suspended":false,"archived":false,"isGuestUser":null}"#,
        #"{"id":"user-id","customerId":"customer-id","suspended":false,"archived":false,"isGuestUser":"false"}"#,
    ])
    func incompleteOrWrongUserNeverAuthorizes(body: String) async {
        let directory = mock(body: body)
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) { try await directory.user(id: "user-id") }
    }

    @Test(arguments: [
        (#"{"suspended":true}"#, WorkspaceDirectoryUser.State.suspended),
        (#"{"archived":true}"#, .archived),
        (#"{"isGuestUser":true}"#, .guest),
        (#"{"deletionTime":"2026-11-01T00:00:00Z"}"#, .deleted),
    ])
    func recognizedInactiveStateIsDenied(extra: String, state: WorkspaceDirectoryUser.State) async throws {
        let body = #"{"id":"user-id","customerId":"customer-id","# + extra.dropFirst()
        let result = try await mock(body: body).user(id: "user-id")
        #expect(result?.state == state)
    }

    @Test func distinguishesAbsentUsersAndConfirmedNonmembersFromUncertainty() async throws {
        let absence = mock(status: 404, body: #"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#)
        #expect(try await absence.user(id: "user-id") == nil)
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await absence.isMember(userID: "user-id", groupID: "group-id")
        }
        #expect(try await mock(body: #"{"isMember":false}"#).isMember(userID: "user-id", groupID: "group-id") == false)
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await mock(body: "{}").isMember(userID: "user-id", groupID: "group-id")
        }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await mock(status: 404, body: "{}").user(id: "user-id")
        }
    }

    @Test(arguments: [
        (403, #"{"error":{"code":403,"errors":[{"reason":"quotaExceeded"}]}}"#, WorkspaceDirectoryFailure.rateLimited),
        (403, #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#, .rateLimited),
        (403, #"{"error":{"code":403,"errors":[{"reason":"quotaExceeded"},{"reason":"forbidden"}]}}"#, .unverifiable),
        (401, "{}", .unverifiable),
        (429, "{}", .rateLimited),
        (503, "{}", .temporarilyUnavailable),
        (302, "{}", .unverifiable),
    ])
    func mapsOnlyKnownRetryableErrors(status: Int, body: String, expected: WorkspaceDirectoryFailure) async {
        await #expect(throws: expected) {
            try await mock(status: status, body: body).isMember(userID: "user-id", groupID: "group-id")
        }
    }

    @Test(arguments: [".", "..", "user@example.test", "a/b", "a%2fb", "a?b"])
    func unsafeIdentifiersNeverReachTheTokenProvider(id: String) async {
        let directory = GoogleWorkspaceDirectory(accessToken: { _ in
            Issue.record("Invalid identifier requested a token")
            return "synthetic"
        }) { _ in
            Issue.record("Invalid identifier reached transport")
            throw WorkspaceDirectoryFailure.unverifiable
        }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) { try await directory.user(id: id) }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await directory.isMember(userID: "user-id", groupID: id)
        }
    }

    @Test func rejectsResponseFromAnotherDestination() async {
        let directory = GoogleWorkspaceDirectory(accessToken: { _ in "synthetic" }) { request in
            try reply(request, body: #"{"isMember":true}"#, url: URL(string: "https://different.invalid/"))
        }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await directory.isMember(userID: "user-id", groupID: "group-id")
        }
    }

    @Test func tokenProviderFailureIsUnverifiable() async {
        let directory = GoogleWorkspaceDirectory(accessToken: { _ in throw URLError(.timedOut) }) { _ in
            Issue.record("Failed token provider reached transport")
            throw WorkspaceDirectoryFailure.unverifiable
        }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) { try await directory.user(id: "user-id") }
    }

    @Test(arguments: [URLError.Code.timedOut, .dnsLookupFailed, .cannotFindHost])
    func transientTransportFailureIsRetryable(code: URLError.Code) async {
        let directory = GoogleWorkspaceDirectory(accessToken: { _ in "synthetic" }) { _ in
            throw URLError(code)
        }
        await #expect(throws: WorkspaceDirectoryFailure.temporarilyUnavailable) {
            try await directory.user(id: "user-id")
        }
    }

    @Test func oversizedBodyIsUnverifiable() async {
        let oversized = mock(body: #"{"isMember":true}"# + String(repeating: " ", count: 32_768))
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) {
            try await oversized.isMember(userID: "user-id", groupID: "group-id")
        }
    }

    @Test func malformedBearerNeverReachesTheTransport() async {
        let directory = GoogleWorkspaceDirectory(accessToken: { _ in "synthetic\r\nX-Injected: value" }) { _ in
            Issue.record("Malformed token reached transport")
            throw WorkspaceDirectoryFailure.unverifiable
        }
        await #expect(throws: WorkspaceDirectoryFailure.unverifiable) { try await directory.user(id: "user-id") }
    }
}

private func mock(status: Int = 200, body: String) -> GoogleWorkspaceDirectory {
    GoogleWorkspaceDirectory(accessToken: { _ in "synthetic" }) { request in
        try reply(request, status: status, body: body)
    }
}

private func reply(
    _ request: URLRequest, status: Int = 200, body: String, url: URL? = nil
) throws -> (Data, HTTPURLResponse) {
    let responseURL = try #require(url ?? request.url)
    let response = try #require(HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: nil))
    return (Data(body.utf8), response)
}
