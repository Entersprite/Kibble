import Foundation

/// The initial ping again, on demand, saying whether the person is active
/// (active-presence spec §4). purple sends it every 120 seconds
/// (`googlechat_connection.c:760-809`); Kibble's channel sent it only once.
/// Its own file because `ChannelSession.swift` is at swiftlint's
/// `file_length`.
public extension ChannelSession {
    /// Only while listening, with that channel's SID and the highest AID
    /// delivered; RID and the stream offset advance as the initial ping's do.
    ///
    /// **Fire-and-forget, and a failure is dropped.** The stream reports its
    /// own failures; applying one from here too could pair two failures with
    /// one reconnect (`ChannelSessionFailurePairingTests`). Nothing is lost
    /// either: the next report goes two minutes later.
    func sendActivityPing(active: Bool) async {
        guard case let .listening(sid) = state.phase else { return }
        requestIdentifier += 1
        let ofs = streamEventOfs
        streamEventOfs += 1
        guard let ping = requests.ping(
            sid: sid, aid: state.highestProcessedAid, rid: requestIdentifier, ofs: ofs, active: active
        ) else { return }
        await Self.acknowledge(
            credentials.authorising(ping), via: transport,
            onHeaders: Self.onPingHeaders(pingURL: ping.url, credentials: credentials),
            onFailure: { _ in }
        )
    }
}
