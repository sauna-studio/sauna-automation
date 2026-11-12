import Testing
import WorkspaceDirectory

private actor DirectoryFixture: WorkspaceDirectoryLookup {
    private var users: [Result<WorkspaceDirectoryUser?, WorkspaceDirectoryFailure>]
    private var memberships: [Result<Bool, WorkspaceDirectoryFailure>]
    private(set) var lookups: [String] = []

    init(
        users: [Result<WorkspaceDirectoryUser?, WorkspaceDirectoryFailure>],
        memberships: [Result<Bool, WorkspaceDirectoryFailure>] = []
    ) {
        self.users = users
        self.memberships = memberships
    }

    func user(id: String) async throws(WorkspaceDirectoryFailure) -> WorkspaceDirectoryUser? {
        lookups.append("user:\(id)")
        guard !users.isEmpty else { throw .unverifiable }
        return try users.removeFirst().get()
    }

    func isMember(userID: String, groupID: String) async throws(WorkspaceDirectoryFailure) -> Bool {
        lookups.append("member:\(userID):\(groupID)")
        guard !memberships.isEmpty else { throw .unverifiable }
        return try memberships.removeFirst().get()
    }
}

private actor Delays {
    private(set) var values: [Duration] = []
    func append(_ duration: Duration) { values.append(duration) }
}

struct EmployeeVerificationTests {
    private let user = WorkspaceDirectoryUser(id: "user-id", customerID: "customer-id", state: .active)

    private func verifier(
        _ directory: DirectoryFixture,
        delays: Delays = Delays(),
        groupID: String = "employee-group-id"
    ) -> WorkspaceEmployeeVerifier {
        .init(directory: directory, customerID: "customer-id", groupID: groupID, sleep: { await delays.append($0) })
    }

    @Test func revokedGroupMembershipIsDeniedOnRecheck() async {
        let directory = DirectoryFixture(users: [.success(user), .success(user)], memberships: [.success(true), .success(false)])
        let verifier = verifier(directory)

        #expect(await verifier.verify(directoryUserID: user.id) == .eligible)
        #expect(await verifier.verify(directoryUserID: user.id) == .ineligible)
        #expect(await directory.lookups == [
            "user:user-id", "member:user-id:employee-group-id",
            "user:user-id", "member:user-id:employee-group-id",
        ])
    }

    @Test(arguments: [WorkspaceDirectoryUser.State.suspended, .archived, .guest, .deleted])
    func inactiveAccountsNeverReachMembershipLookup(state: WorkspaceDirectoryUser.State) async {
        let directory = DirectoryFixture(users: [.success(.init(id: user.id, customerID: user.customerID, state: state))])
        #expect(await verifier(directory).verify(directoryUserID: user.id) == .ineligible)
        #expect(await directory.lookups == ["user:user-id"])
    }

    @Test func absentAndWrongTenantUsersAreIneligible() async {
        let foreignUser = WorkspaceDirectoryUser(id: user.id, customerID: "foreign-customer", state: .active)
        let directory = DirectoryFixture(users: [.success(nil), .success(foreignUser)])
        let verifier = verifier(directory)

        #expect(await verifier.verify(directoryUserID: user.id) == .ineligible)
        #expect(await verifier.verify(directoryUserID: user.id) == .ineligible)
        #expect(await directory.lookups == ["user:user-id", "user:user-id"])
    }

    @Test(arguments: ["another-id", "user-K"])
    func responseForAnotherUserIsUnverifiable(returnedID: String) async {
        let wrongUser = WorkspaceDirectoryUser(id: returnedID, customerID: user.customerID, state: .active)
        let directory = DirectoryFixture(users: [.success(wrongUser)])
        #expect(await verifier(directory).verify(directoryUserID: "user-K") == .unavailable)
        #expect(await directory.lookups == ["user:user-K"])
    }

    @Test func invalidIdentifiersDoNotCallProvider() async {
        let directory = DirectoryFixture(users: [])
        #expect(await verifier(directory).verify(directoryUserID: "person@example.test") == .unavailable)
        #expect(await verifier(directory, groupID: "").verify(directoryUserID: user.id) == .unavailable)
        #expect(await directory.lookups.isEmpty)
    }

    @Test func transientAndRateLimitedOperationsCanRecover() async {
        let directory = DirectoryFixture(
            users: [.failure(.temporarilyUnavailable), .success(user)],
            memberships: [.failure(.rateLimited), .failure(.temporarilyUnavailable), .success(true)]
        )
        let delays = Delays()

        #expect(await verifier(directory, delays: delays).verify(directoryUserID: user.id) == .eligible)
        #expect(await directory.lookups == [
            "user:user-id", "user:user-id",
            "member:user-id:employee-group-id", "member:user-id:employee-group-id", "member:user-id:employee-group-id",
        ])
        #expect(await delays.values == [.milliseconds(200), .milliseconds(200), .milliseconds(400)])
    }

    @Test func exhaustedRateLimitNeverUsesALaterSuccess() async {
        let directory = DirectoryFixture(
            users: [.success(user)],
            memberships: [.failure(.rateLimited), .failure(.rateLimited), .failure(.rateLimited), .success(true)]
        )
        let delays = Delays()

        #expect(await verifier(directory, delays: delays).verify(directoryUserID: user.id) == .unavailable)
        #expect(await directory.lookups.count == 4)
        #expect(await delays.values == [.milliseconds(200), .milliseconds(400)])
    }

    @Test func permanentFailureIsNotRetried() async {
        let directory = DirectoryFixture(users: [.failure(.unverifiable), .success(user)], memberships: [.success(true)])
        let delays = Delays()

        #expect(await verifier(directory, delays: delays).verify(directoryUserID: user.id) == .unavailable)
        #expect(await directory.lookups == ["user:user-id"])
        #expect(await delays.values.isEmpty)
    }

    @Test func interruptedBackoffDoesNotResumeVerification() async {
        let directory = DirectoryFixture(users: [.failure(.rateLimited), .success(user)], memberships: [.success(true)])
        let verifier = WorkspaceEmployeeVerifier(directory: directory, customerID: user.customerID, groupID: "employee-group-id") { _ in
            throw CancellationError()
        }

        #expect(await verifier.verify(directoryUserID: user.id) == .unavailable)
        #expect(await directory.lookups == ["user:user-id"])
    }
}
