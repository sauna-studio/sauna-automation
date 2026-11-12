public struct WorkspaceDirectoryUser: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case active
        case suspended
        case archived
        case guest
        case deleted
    }

    public let id: String
    public let customerID: String
    public let state: State

    public init(id: String, customerID: String, state: State) {
        self.id = id
        self.customerID = customerID
        self.state = state
    }
}

public enum WorkspaceDirectoryFailure: Error, Sendable {
    case rateLimited
    case temporarilyUnavailable
    case unverifiable
}

public protocol WorkspaceDirectoryLookup: Sendable {
    /// Return nil only for an authoritatively absent user. Unknown account state throws `.unverifiable`.
    func user(id: String) async throws(WorkspaceDirectoryFailure) -> WorkspaceDirectoryUser?

    /// Return false only after the provider confirms non-membership. Uncertain results throw `.unverifiable`.
    func isMember(userID: String, groupID: String) async throws(WorkspaceDirectoryFailure) -> Bool
}

public enum EmployeeVerification: Equatable, Sendable {
    case eligible
    case ineligible
    case unavailable
}

public struct WorkspaceEmployeeVerifier: Sendable {
    private let directory: any WorkspaceDirectoryLookup
    private let customerID: String
    private let groupID: String
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        directory: any WorkspaceDirectoryLookup,
        customerID: String,
        groupID: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.directory = directory
        self.customerID = customerID
        self.groupID = groupID
        self.sleep = sleep
    }

    /// The caller supplies a previously linked immutable Directory user ID.
    public func verify(directoryUserID: String) async -> EmployeeVerification {
        guard [directoryUserID, customerID, groupID].allSatisfy(Self.isOpaqueID) else {
            return .unavailable
        }

        do {
            guard let user = try await retry({ () async throws(WorkspaceDirectoryFailure) in
                try await directory.user(id: directoryUserID)
            }) else {
                return .ineligible
            }
            guard user.id.utf8.elementsEqual(directoryUserID.utf8) else { return .unavailable }
            guard user.customerID.utf8.elementsEqual(customerID.utf8), user.state == .active else {
                return .ineligible
            }
            let isMember = try await retry { () async throws(WorkspaceDirectoryFailure) in
                try await directory.isMember(userID: directoryUserID, groupID: groupID)
            }
            return isMember ? .eligible : .ineligible
        } catch {
            return .unavailable
        }
    }

    private func retry<Value>(
        _ operation: () async throws(WorkspaceDirectoryFailure) -> Value
    ) async throws -> Value {
        let delays: [Duration] = [.milliseconds(200), .milliseconds(400)]
        for delay in delays {
            try Task.checkCancellation()
            do {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            } catch let failure as WorkspaceDirectoryFailure {
                switch failure {
                case .rateLimited, .temporarilyUnavailable:
                    try Task.checkCancellation()
                    try await sleep(delay)
                case .unverifiable:
                    throw failure
                }
            }
        }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private static func isOpaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) && $0 != 64 }
    }
}
