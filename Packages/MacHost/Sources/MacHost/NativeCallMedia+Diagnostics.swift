import Foundation
@preconcurrency import WebRTC

public extension NativeCallMedia {
    /// Read-only, on-demand sampling. This never creates a peer or audio track,
    /// requests microphone access, changes mute, or sends signaling.
    func diagnosticReport() async -> [String] {
        guard !Task.isCancelled else { return ["Native media diagnostics: canceled"] }
        guard let connection = peer else { return ["Native media diagnostics: no peer"] }
        let scope = generation
        let first = await Self.audioStatistics(connection)
        guard diagnosticsAreCurrent(scope, connection)
        else { return ["Native media diagnostics: superseded"] }
        guard let first else {
            return diagnosticStates(connection) + ["Native media statistics: first sample unavailable"]
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return ["Native media diagnostics: canceled"] }
        guard diagnosticsAreCurrent(scope, connection)
        else { return ["Native media diagnostics: superseded"] }
        let second = await Self.audioStatistics(connection)
        guard diagnosticsAreCurrent(scope, connection)
        else { return ["Native media diagnostics: superseded"] }
        guard let second else {
            return diagnosticStates(connection) + ["Native media statistics: second sample unavailable"]
        }
        return diagnosticStates(connection) + second.report(comparedWith: first)
    }

    private func diagnosticsAreCurrent(_ scope: UUID, _ connection: RTCPeerConnection) -> Bool {
        !Task.isCancelled && generation == scope && peer === connection
    }

    private static func audioStatistics(_ connection: RTCPeerConnection) async -> NativeAudioStatistics? {
        let waiter = NativeMediaDiagnosticWaiter()
        let localAudioSSRC = NativeAudioSourceMatch.localAudioSSRC(connection.localDescription?.sdp)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                guard waiter.isPending else { return }
                waiter.armTimeout(.seconds(2))
                connection.statistics { report in
                    guard waiter.isPending else { return }
                    var audio = NativeAudioStatistics()
                    if report.statistics.count > NativeAudioStatistics.maximumRecords {
                        audio.isBounded = false
                    } else {
                        for record in report.statistics.values {
                            audio.add(
                                type: record.type,
                                values: record.values,
                                localAudioSSRC: localAudioSSRC
                            )
                        }
                    }
                    waiter.finish(audio)
                }
            }
        } onCancel: {
            waiter.finish(nil)
        }
    }

    private func diagnosticStates(_ connection: RTCPeerConnection) -> [String] {
        let senders = connection.senders.compactMap(\.track)
            .filter { $0.kind == kRTCMediaStreamTrackKindAudio }
        let receivers = connection.receivers.compactMap(\.track)
            .filter { $0.kind == kRTCMediaStreamTrackKindAudio }
        let transceivers = connection.transceivers.filter { $0.mediaType == .audio }
        let directions = transceivers.prefix(16).map { transceiver in
            var current = RTCRtpTransceiverDirection.inactive
            return transceiver.currentDirection(&current) ? Self.directionLabel(current) : "not negotiated"
        }
        let negotiated = directions.isEmpty ? "none" : directions.joined(separator: ", ")
        return [
            "Native media peer state: \(Self.peerLabel(connection.connectionState))",
            "Native media ICE state: \(Self.iceLabel(connection.iceConnectionState))",
            "Native media microphone muted: \(isMicrophoneMuted ? "yes" : "no")",
            Self.trackLine("senders", senders), Self.trackLine("receivers", receivers),
            "Native media audio negotiated directions: \(negotiated)"
        ]
    }

    private static func trackLine(_ label: String, _ tracks: [RTCMediaStreamTrack]) -> String {
        let enabled = tracks.count { $0.isEnabled }
        let live = tracks.count { $0.readyState == .live }
        return "Native media audio \(label): tracks=\(tracks.count); enabled=\(enabled); live=\(live)"
    }

    private static func peerLabel(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: "new"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        @unknown default: "unknown"
        }
    }

    private static func iceLabel(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        case .count: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func directionLabel(_ direction: RTCRtpTransceiverDirection) -> String {
        switch direction {
        case .sendRecv: "send and receive"
        case .sendOnly: "send only"
        case .recvOnly: "receive only"
        case .inactive: "inactive"
        case .stopped: "stopped"
        @unknown default: "unknown"
        }
    }
}
