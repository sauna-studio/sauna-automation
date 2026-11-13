import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleWorkspaceDirectory: WorkspaceDirectoryLookup {
    public enum Scope: String, Sendable {
        case userReadOnly = "https://www.googleapis.com/auth/admin.directory.user.readonly"
        case groupMembershipReadOnly = "https://www.googleapis.com/auth/admin.directory.group.member.readonly"
    }

    private let accessToken: @Sendable (Scope) throws -> String
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Supply an already available token for the requested scope. Consent and token refresh belong to the caller.
    public init(accessToken: @escaping @Sendable (Scope) throws -> String) {
        let session = Self.session
        self.init(accessToken: accessToken) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw WorkspaceDirectoryFailure.unverifiable }
            return (data, response)
        }
    }

    private static let session = makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    init(
        accessToken: @escaping @Sendable (Scope) throws -> String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) {
        self.accessToken = accessToken
        self.transport = transport
    }

    public func user(id: String) async throws(WorkspaceDirectoryFailure) -> WorkspaceDirectoryUser? {
        guard Self.isPathID(id) else { throw .unverifiable }
        let (data, status) = try await request(
            path: "/users/\(id)",
            query: [
                URLQueryItem(name: "viewType", value: "admin_view"),
                URLQueryItem(name: "fields", value: "id,customerId,suspended,archived,isGuestUser,deletionTime"),
            ],
            scope: .userReadOnly
        )
        if status == 404, Self.reasons(in: data, status: status) == ["notFound"] { return nil }
        try Self.requireSuccess(status, data: data)
        guard let user = try? JSONDecoder().decode(User.self, from: data),
              user.id.utf8.elementsEqual(id.utf8),
              Self.isPathID(user.customerId) else {
            throw .unverifiable
        }
        let state: WorkspaceDirectoryUser.State
        if user.deletionTime != nil { state = .deleted }
        else if user.suspended == true { state = .suspended }
        else if user.archived == true { state = .archived }
        else if user.isGuestUser == true { state = .guest }
        else if user.suspended == false, user.archived == false, user.isGuestUser == false { state = .active }
        else { throw .unverifiable }
        return WorkspaceDirectoryUser(id: user.id, customerID: user.customerId, state: state)
    }

    public func isMember(userID: String, groupID: String) async throws(WorkspaceDirectoryFailure) -> Bool {
        guard Self.isPathID(userID), Self.isPathID(groupID) else { throw .unverifiable }
        let (data, status) = try await request(path: "/groups/\(groupID)/hasMember/\(userID)", scope: .groupMembershipReadOnly)
        try Self.requireSuccess(status, data: data)
        guard let membership = try? JSONDecoder().decode(Membership.self, from: data) else { throw .unverifiable }
        return membership.isMember
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        scope: Scope
    ) async throws(WorkspaceDirectoryFailure) -> (Data, Int) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "admin.googleapis.com"
        components.path = "/admin/directory/v1" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, !Task.isCancelled else { throw .unverifiable }
        guard let token = try? accessToken(scope), !token.isEmpty, token.utf8.count <= 8_192,
              token.utf8.allSatisfy(Self.isBearerByte), !Task.isCancelled else { throw .unverifiable }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport(request)
            guard response.url == url, data.count <= 32_768, !Task.isCancelled else {
                throw WorkspaceDirectoryFailure.unverifiable
            }
            return (data, response.statusCode)
        } catch let error as URLError {
            guard !Task.isCancelled else { throw .unverifiable }
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .dnsLookupFailed, .cannotFindHost:
                throw .temporarilyUnavailable
            default:
                throw .unverifiable
            }
        } catch {
            throw .unverifiable
        }
    }

    private static func requireSuccess(_ status: Int, data: Data) throws(WorkspaceDirectoryFailure) {
        switch status {
        case 200:
            return
        case 429:
            throw .rateLimited
        case 403:
            let quotaReasons: Set<String> = ["userRateLimitExceeded", "quotaExceeded"]
            let reasons = reasons(in: data, status: status)
            if !reasons.isEmpty, reasons.isSubset(of: quotaReasons) { throw .rateLimited }
            throw .unverifiable
        case 500, 502, 503, 504:
            throw .temporarilyUnavailable
        default:
            throw .unverifiable
        }
    }

    private static func reasons(in data: Data, status: Int) -> Set<String> {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              envelope.error.code == status else { return [] }
        return Set(envelope.error.errors.map(\.reason))
    }

    private static func isPathID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { byte in
            switch byte {
            case 45, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }
    }

    private static func isBearerByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 43, 45...57, 61, 65...90, 95, 97...122, 126: true
        default: false
        }
    }

    private struct User: Decodable {
        let id: String
        let customerId: String
        let suspended: Bool?
        let archived: Bool?
        let isGuestUser: Bool?
        let deletionTime: String?
    }

    private struct Membership: Decodable {
        let isMember: Bool
    }

    private struct ErrorEnvelope: Decodable {
        struct Failure: Decodable {
            struct Detail: Decodable {
                let reason: String
            }

            let code: Int
            let errors: [Detail]
        }

        let error: Failure
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
