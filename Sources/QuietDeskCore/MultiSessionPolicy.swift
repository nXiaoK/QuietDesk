import Foundation

public struct RemoteSessionTargetIdentity: Equatable, Hashable, Sendable {
    public let recordID: UUID?
    public let directEndpoint: String?
    public let relayDeviceID: UUID?

    public init(
        recordID: UUID? = nil,
        address: String = "",
        port: UInt16 = 5908,
        relayDeviceID: UUID? = nil
    ) {
        self.recordID = recordID
        self.directEndpoint = RouteBenchmarkTargetDescriptor.normalizedDirectEndpoint(
            address: address,
            port: port
        )
        self.relayDeviceID = relayDeviceID
    }

    public var hasIdentity: Bool {
        recordID != nil || directEndpoint != nil || relayDeviceID != nil
    }

    public func matches(_ other: RemoteSessionTargetIdentity) -> Bool {
        if let recordID, let otherRecordID = other.recordID, recordID == otherRecordID {
            return true
        }
        if let relayDeviceID, let otherRelayID = other.relayDeviceID, relayDeviceID == otherRelayID {
            return true
        }
        if let directEndpoint, let otherDirect = other.directEndpoint, directEndpoint == otherDirect {
            return true
        }
        return false
    }
}

public struct ActiveRemoteSessionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: RemoteSessionTargetIdentity
    public let title: String
    public let endpointLabel: String
    public let statusLabel: String
    public let connected: Bool
    public let reconnecting: Bool
    public let working: Bool

    public init(
        id: UUID,
        target: RemoteSessionTargetIdentity,
        title: String,
        endpointLabel: String,
        statusLabel: String,
        connected: Bool,
        reconnecting: Bool,
        working: Bool
    ) {
        self.id = id
        self.target = target
        self.title = title
        self.endpointLabel = endpointLabel
        self.statusLabel = statusLabel
        self.connected = connected
        self.reconnecting = reconnecting
        self.working = working
    }
}

public enum MultiSessionPolicy {
    /// Host sharing accepts one incoming controller at a time, regardless of how many outgoing
    /// remote control sessions (`B -> D`, `B -> E`) this Mac is currently running.
    public static func allowsIncomingHostConnection(
        existingHostPeerActive: Bool,
        outgoingViewerSessionCount: Int
    ) -> Bool {
        _ = outgoingViewerSessionCount
        return !existingHostPeerActive
    }

    /// Outgoing viewer sessions and route quality benchmarks are allowed even while another Mac
    /// is actively controlling this Mac (`A -> B` while `B -> D`).
    public static func allowsOutgoingViewerConnection(
        hasIncomingHostConnection: Bool,
        activeBenchmarkRunning: Bool
    ) -> Bool {
        _ = hasIncomingHostConnection
        return !activeBenchmarkRunning
    }

    /// Returns the ID of an already-active viewer session targeting the same remote Mac, so
    /// clicking Connect focuses its window instead of opening a conflicting second session.
    public static func existingSessionID(
        matching candidate: RemoteSessionTargetIdentity,
        in sessions: [(id: UUID, target: RemoteSessionTargetIdentity)]
    ) -> UUID? {
        guard candidate.hasIdentity else { return nil }
        return sessions.first(where: { $0.target.matches(candidate) })?.id
    }

    /// Computes which device IDs should have `.session`-scoped port mappings stopped when one
    /// viewer session clears, keeping `.session` mappings for other connected Macs running.
    public static func deviceIDsToStopSessionMappings(
        disconnectedDeviceID: UUID?,
        remainingConnectedDeviceIDs: Set<UUID>
    ) -> Set<UUID> {
        guard let disconnectedDeviceID, !remainingConnectedDeviceIDs.contains(disconnectedDeviceID) else {
            return []
        }
        return [disconnectedDeviceID]
    }

    /// Port mapping traffic yields bandwidth whenever the host session or any viewer session
    /// has an active desktop control/media peer.
    public static func isDesktopTrafficActive(
        hostPeerActive: Bool,
        viewerPeersActiveCount: Int
    ) -> Bool {
        hostPeerActive || viewerPeersActiveCount > 0
    }
}
