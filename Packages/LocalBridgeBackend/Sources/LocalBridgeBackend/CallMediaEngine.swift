import ChatKit
import Foundation

/// Platform-owned WebRTC engine injected into the local call adapter. SDP and
/// ICE credentials are ephemeral signaling values; never store or report them.
@MainActor
public protocol CallMediaEngine: AnyObject, Sendable {
    var isConnected: Bool { get }
    var supportsStreamControl: Bool { get }
    var supportsActivityChannelAssignments: Bool { get }
    var supportsGzipActivityChannels: Bool { get }
    var supportsVideo: Bool { get }
    var supportsScreenSharing: Bool { get }
    var sendsPresentationAudio: Bool { get }
    var allowsMicrophone: Bool { get }
    func confirmAdmission(_ notices: [CallAdmissionNotice]) async -> Bool
    func prepareActivityChannel(_ label: String) async throws
    func sendActivityData(channel: String, data: Data) async throws
    func exchangeActivityData(
        channel: String,
        data: Data,
        matches: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data
    func remoteAudioLevels() -> [CallAudioSourceLevel]
    func localAudioActivity() async -> CallLocalAudioActivity?
    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    )
    func setScreenSharingAllowed(_ allowed: Bool)
    func setCaptureAllowed(microphone: Bool, camera: Bool)
    func remoteVideoPreferences() -> CallVideoPreferences
    func showRemoteVideos(_ slots: [CallRemoteVideoSlot])
    func showRemotePresentation(_ visible: Bool)
    func renewVideoOffer() async throws -> CallAudioOffer
    func applyVideoAnswer(_ sdp: String) async throws
    func cancelVideoOffer() async
    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?)
    func startCameraForJoin()
    func reportVideoUnavailable()
    func showRemoteVideo(_ visible: Bool)
    var isMicrophoneMuted: Bool { get }
    /// Prepare bundled SCTP when a server-created control channel is expected.
    /// isConnected stays false until that channel is open as well as the peer.
    func makeAudioOffer(serverControlChannel: String?) async throws -> CallAudioOffer
    func applyAnswer(_ sdp: String) async throws
    func waitUntilConnected(timeout: Duration) async throws
    func setEventHandler(_ handler: (@Sendable (CallMediaEvent) async -> Void)?)
    func setMuted(_ muted: Bool)
    func prepareMutedMeetingJoin()
    func authorizeMicrophone() async -> Bool
    /// A server-assigned SCTP channel is negotiated before applying the answer.
    /// Nil preserves the legacy in-band channel path.
    func configureStreamControl(_ channel: CallStreamControlChannel?) throws
    func configureActivityChannel(_ channel: CallStreamControlChannel, label: String) throws
    func exchangeStreamControl(
        _ request: Data, matches: @escaping @Sendable (Data) -> Bool, timeout: Duration
    ) async throws -> Data
    /// Fixed control-transport phases/counts only, sampled before failure cleanup.
    func streamControlDiagnosticReport() -> [String]
    /// On-demand, bounded media-flow diagnostics. Fixed labels and aggregate
    /// counters only; no device names, identifiers, signaling or audio samples.
    func diagnosticReport() async -> [String]
    func close()
}

public enum CallMediaEvent: Sendable {
    case activityData(channel: String, data: Data)
    case activityClosed(channel: String)
    case collectionsChanged
    case connected
    case disconnected
    case failed
    /// Host suspension is distinct from an audio transport failure. A paired
    /// resume gives the existing peer a fresh bounded opportunity to recover.
    case suspended, resumed
}

public struct CallLocalAudioActivity: Sendable {
    public let level: Double
    public let timestamp: Double

    public init(level: Double, timestamp: Double) {
        self.level = level
        self.timestamp = timestamp
    }
}

public extension CallMediaEngine {
    func prepareMutedMeetingJoin() {
        setMuted(true)
    }

    func authorizeMicrophone() async -> Bool {
        true
    }

    func startCameraForJoin() {}

    func confirmAdmission(_: [CallAdmissionNotice]) async -> Bool {
        false
    }

    func configureStreamControl(_ channel: CallStreamControlChannel?) throws {
        guard channel == nil else { throw CallMediaError.negotiationFailed }
    }

    var supportsActivityChannelAssignments: Bool {
        false
    }

    var supportsGzipActivityChannels: Bool {
        false
    }

    func configureActivityChannel(_: CallStreamControlChannel, label _: String) throws {
        throw CallMediaError.negotiationFailed
    }

    func streamControlDiagnosticReport() -> [String] {
        []
    }

    func prepareActivityChannel(_: String) async throws {
        throw CallMediaError.connectionFailed
    }

    func sendActivityData(channel _: String, data _: Data) async throws {
        throw CallMediaError.connectionFailed
    }

    func exchangeActivityData(
        channel _: String,
        data _: Data,
        matches _: @escaping @Sendable (Data) -> Bool
    ) async throws
        -> Data {
        throw CallMediaError.connectionFailed
    }

    func remoteAudioLevels() -> [CallAudioSourceLevel] {
        []
    }

    func localAudioActivity() async -> CallLocalAudioActivity? {
        nil
    }

    var sendsPresentationAudio: Bool {
        false
    }

    var supportsScreenSharing: Bool {
        false
    }

    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    ) {}
    func setScreenSharingAllowed(_: Bool) {}
    var allowsMicrophone: Bool {
        true
    }

    func setCaptureAllowed(microphone: Bool, camera _: Bool) {
        if !microphone {
            setMuted(true)
        }
    }

    func remoteVideoPreferences() -> CallVideoPreferences {
        CallVideoPreferences()
    }

    func showRemoteVideos(_ slots: [CallRemoteVideoSlot]) {
        showRemotePresentation(slots.first.map(\.isPresentation) ?? false)
        showRemoteVideo(slots.first?.isVisible ?? false)
    }

    func showRemotePresentation(_: Bool) {}

    var supportsVideo: Bool {
        false
    }

    func renewVideoOffer() async throws -> CallAudioOffer {
        throw CallMediaError.negotiationFailed
    }

    func applyVideoAnswer(_ sdp: String) async throws {
        try await applyAnswer(sdp)
    }

    func cancelVideoOffer() async {}
    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?) {}
    func reportVideoUnavailable() {}
    func showRemoteVideo(_: Bool) {}

    func diagnosticReport() async -> [String] {
        []
    }

    var supportsStreamControl: Bool {
        false
    }

    var isMicrophoneMuted: Bool {
        false
    }

    func exchangeStreamControl(
        _: Data, matches _: @escaping @Sendable (Data) -> Bool, timeout _: Duration
    ) async throws -> Data {
        throw CallMediaError.connectionFailed
    }

    func setEventHandler(_: (@Sendable (CallMediaEvent) async -> Void)?) {}

    func makeAudioOffer() async throws -> CallAudioOffer {
        try await makeAudioOffer(serverControlChannel: nil)
    }
}

/// Private media-port values. SSRCs remain inside the provider/native binding;
/// only call-local participant UUIDs and speaking state reach clients.
public struct CallAudioSourceLevel: Sendable {
    public let source: UInt32
    public let level: Double
    public let timestamp: Double
    public init(source: UInt32, level: Double, timestamp: Double) {
        self.source = source; self.level = level; self.timestamp = timestamp
    }
}

/// DTLS-SRTP preference is not represented in the SDP fingerprint. Carry the
/// engine's actual preference alongside its offer instead of guessing it in
/// the provider encoder. These names contain no provider identifiers.
public enum CallSRTPProfile: String, Sendable {
    case aes128SHA180 = "AES_CM_128_HMAC_SHA1_80"
    case aeadAES128GCM = "AEAD_AES_128_GCM"
    case aeadAES256GCM = "AEAD_AES_256_GCM"
}

public struct CallAudioOffer: Sendable {
    public let sdp: String
    public let srtpProfile: CallSRTPProfile

    public init(sdp: String, srtpProfile: CallSRTPProfile) {
        self.sdp = sdp
        self.srtpProfile = srtpProfile
    }
}

public enum CallMediaError: Error, Sendable, Equatable {
    case microphoneDenied, busy, closed, negotiationFailed, connectionFailed, timedOut
    case outgoingAudioUnconfirmed, signalingTimedOut
    case sharingRestricted
    case captureRestricted
}

public enum CallDataChannelCompression: Sendable, Equatable {
    case none
    case gzip
}

public struct CallStreamControlChannel: Sendable, Equatable {
    public let id: UInt16
    public let isOrdered: Bool
    public let maxPacketLifeTime: UInt16?
    public let maxRetransmits: UInt16?
    public let compression: CallDataChannelCompression
    public init(
        id: UInt16, isOrdered: Bool, maxPacketLifeTime: UInt16? = nil, maxRetransmits: UInt16? = nil,
        compression: CallDataChannelCompression = .none
    ) {
        self.id = id; self.isOrdered = isOrdered
        self.maxPacketLifeTime = maxPacketLifeTime; self.maxRetransmits = maxRetransmits
        self.compression = compression
    }
}

/// Local receive-transceiver index; provider stream/device identifiers stay in
/// the signaling owner. The host retains independent tracks for simultaneous media.
public struct CallRemoteVideoSlot: Sendable, Equatable {
    public let index: Int
    public let isPresentation: Bool
    public let isVisible: Bool
    public let participantID: UUID?
    public let displayName: String?

    public init(
        index: Int, isPresentation: Bool, isVisible: Bool, participantID: UUID? = nil,
        displayName: String? = nil
    ) {
        self.index = index
        self.isPresentation = isPresentation
        self.isVisible = isVisible
        self.participantID = participantID
        self.displayName = displayName
    }
}
