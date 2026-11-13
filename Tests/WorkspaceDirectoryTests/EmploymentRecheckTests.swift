import Testing
import WorkspaceDirectory

private struct RecheckDirectory: WorkspaceDirectoryLookup {
    var membership: Result<Bool, WorkspaceDirectoryFailure>

    func user(id: String) async throws(WorkspaceDirectoryFailure) -> WorkspaceDirectoryUser? {
        .init(id: id, customerID: "tenant-1", state: .active)
    }

    func isMember(userID: String, groupID: String) async throws(WorkspaceDirectoryFailure) -> Bool {
        try membership.get()
    }
}

private actor RevocationFixture: WorkspaceEmploymentRevocationStore {
    private var current: WorkspaceEmploymentSnapshot?
    private let cancelAfterCommit: Bool
    private let loseCommitResponse: Bool
    private(set) var attempts = 0
    private(set) var auditCount = 0

    init(current: WorkspaceEmploymentSnapshot, cancelAfterCommit: Bool = false, loseCommitResponse: Bool = false) {
        self.current = current
        self.cancelAfterCommit = cancelAfterCommit
        self.loseCommitResponse = loseCommitResponse
    }

    func revokeIfCurrent(_ snapshot: WorkspaceEmploymentSnapshot) async throws -> WorkspaceEmploymentRevocation {
        attempts += 1
        guard let current,
              current.saunaUserID == snapshot.saunaUserID,
              current.directoryUserID == snapshot.directoryUserID,
              current.customerID == snapshot.customerID,
              current.groupID == snapshot.groupID,
              current.revision == snapshot.revision else { return .snapshotNoLongerCurrent }
        self.current = nil
        auditCount += 1
        if cancelAfterCommit { withUnsafeCurrentTask { $0?.cancel() } }
        if loseCommitResponse { throw CancellationError() }
        return .revoked
    }
}

struct EmploymentRecheckTests {
    private let snapshot = WorkspaceEmploymentSnapshot(
        saunaUserID: "sauna-user-1", directoryUserID: "directory-user-1",
        customerID: "tenant-1", groupID: "staff-group-1", revision: 7
    )

    @Test(arguments: [true, false])
    func eligibleAndUnverifiableMembershipNeverWrite(eligible: Bool) async {
        let store = RevocationFixture(current: snapshot)
        let directory = RecheckDirectory(membership: eligible ? .success(true) : .failure(.unverifiable))
        let result = await WorkspaceEmploymentRechecker(directory: directory, revocations: store).recheck(snapshot)
        #expect(result == (eligible ? .eligible : .verificationUnavailable))
        #expect(await store.attempts == 0)
    }

    @Test func staleRevisionCannotRevokeTheCurrentBinding() async {
        let store = RevocationFixture(current: .init(
            saunaUserID: snapshot.saunaUserID, directoryUserID: snapshot.directoryUserID,
            customerID: snapshot.customerID, groupID: snapshot.groupID, revision: snapshot.revision + 1
        ))
        let rechecker = WorkspaceEmploymentRechecker(directory: RecheckDirectory(membership: .success(false)), revocations: store)
        #expect(await rechecker.recheck(snapshot) == .snapshotNoLongerCurrent)
        #expect(await store.auditCount == 0)
    }

    @Test func concurrentNegativeChecksRevokeAndAuditOnce() async {
        let store = RevocationFixture(current: snapshot)
        let rechecker = WorkspaceEmploymentRechecker(directory: RecheckDirectory(membership: .success(false)), revocations: store)
        async let first = rechecker.recheck(snapshot)
        async let second = rechecker.recheck(snapshot)
        let results = await [first, second]
        #expect(results.filter { $0 == .revoked }.count == 1)
        #expect(results.filter { $0 == .snapshotNoLongerCurrent }.count == 1)
        #expect(await store.auditCount == 1)
    }

    @Test func cancellationBeforeVerificationDoesNotWrite() async {
        let store = RevocationFixture(current: snapshot)
        let rechecker = WorkspaceEmploymentRechecker(directory: RecheckDirectory(membership: .success(false)), revocations: store)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await rechecker.recheck(snapshot)
        }.value
        #expect(result == .cancelled)
        #expect(await store.attempts == 0)
    }

    @Test func cancellationAfterAnAcknowledgedCommitReportsRevocation() async {
        let store = RevocationFixture(current: snapshot, cancelAfterCommit: true)
        let rechecker = WorkspaceEmploymentRechecker(directory: RecheckDirectory(membership: .success(false)), revocations: store)
        let result = await Task { await rechecker.recheck(snapshot) }.value
        #expect(result == .revoked)
        #expect(await store.auditCount == 1)
    }

    @Test func lostCommitResponseReportsUnknownAndRetryCannotWriteTwice() async {
        let store = RevocationFixture(current: snapshot, loseCommitResponse: true)
        let rechecker = WorkspaceEmploymentRechecker(directory: RecheckDirectory(membership: .success(false)), revocations: store)
        #expect(await rechecker.recheck(snapshot) == .revocationOutcomeUnknown)
        #expect(await rechecker.recheck(snapshot) == .snapshotNoLongerCurrent)
        #expect(await store.auditCount == 1)
    }
}
