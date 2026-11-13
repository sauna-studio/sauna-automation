/// A trusted Sauna-side view of an active employment binding and its verification policy.
public struct WorkspaceEmploymentSnapshot: Sendable {
    public let saunaUserID: String
    public let directoryUserID: String
    public let customerID: String
    public let groupID: String
    public let revision: UInt64

    public init(saunaUserID: String, directoryUserID: String, customerID: String, groupID: String, revision: UInt64) {
        self.saunaUserID = saunaUserID
        self.directoryUserID = directoryUserID
        self.customerID = customerID
        self.groupID = groupID
        self.revision = revision
    }
}

public enum WorkspaceEmploymentRevocation: Sendable {
    case revoked
    case snapshotNoLongerCurrent
}

public protocol WorkspaceEmploymentRevocationStore: Sendable {
    /// Atomically compare the active binding, policy and revision before removing its employee access and recording the audit.
    /// The caller must obtain the snapshot from trusted storage and reserve a new revision when starting each recheck.
    /// Newer rechecks and changes to the binding, policy or access must invalidate older revisions, including after recreation.
    /// A throw leaves the commit outcome unknown. A retry with the same snapshot must not repeat a committed revocation.
    func revokeIfCurrent(_ snapshot: WorkspaceEmploymentSnapshot) async throws -> WorkspaceEmploymentRevocation
}

public enum WorkspaceEmploymentRecheckResult: Equatable, Sendable {
    /// A point-in-time Directory observation. It must never grant or extend Sauna access.
    case eligible
    case verificationUnavailable
    case cancelled
    case revoked
    case snapshotNoLongerCurrent
    case revocationOutcomeUnknown
}

public struct WorkspaceEmploymentRechecker: Sendable {
    private let directory: any WorkspaceDirectoryLookup
    private let revocations: any WorkspaceEmploymentRevocationStore

    public init(directory: any WorkspaceDirectoryLookup, revocations: any WorkspaceEmploymentRevocationStore) {
        self.directory = directory
        self.revocations = revocations
    }

    public func recheck(_ snapshot: WorkspaceEmploymentSnapshot) async -> WorkspaceEmploymentRecheckResult {
        guard !Task.isCancelled else { return .cancelled }
        let verifier = WorkspaceEmployeeVerifier(
            directory: directory,
            customerID: snapshot.customerID,
            groupID: snapshot.groupID
        )
        let verification = await verifier.verify(directoryUserID: snapshot.directoryUserID)
        guard !Task.isCancelled else { return .cancelled }
        switch verification {
        case .eligible: return .eligible
        case .unavailable: return .verificationUnavailable
        case .ineligible:
            do {
                switch try await revocations.revokeIfCurrent(snapshot) {
                case .revoked: return .revoked
                case .snapshotNoLongerCurrent: return .snapshotNoLongerCurrent
                }
            } catch {
                // Cancellation or a transport error can arrive after the commit.
                return .revocationOutcomeUnknown
            }
        }
    }
}
