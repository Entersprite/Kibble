import Foundation

public extension ChannelSession {
    /// Retain one local receive interest across channel registration/reconnect.
    /// Nil forgets it locally; the protocol has no verified unsubscribe operation.
    func watchGroup(_ group: GroupId?) async {
        guard !Task.isCancelled, !state.phase.isTerminal else { return }
        watchedGroup = group
        await sendGroupSubscription()
    }
}

extension ChannelSession {
    func prepareGroupSubscription(sid: String) async {
        guard !Task.isCancelled, state.phase.sid == sid else { return }
        subscriptionReadySID = sid
        await sendGroupSubscription()
    }

    private func sendGroupSubscription() async {
        guard !Task.isCancelled, let group = watchedGroup, let sid = state.phase.sid,
              subscriptionReadySID == sid else { return }
        requestIdentifier += 1
        let ofs = streamEventOfs
        streamEventOfs += 1
        guard let request = requests.subscribe(
            group: group, sid: sid, aid: state.highestProcessedAid, rid: requestIdentifier, ofs: ofs
        ) else { return }
        let authorised = await credentials.authorising(request)
        guard !Task.isCancelled, watchedGroup == group, state.phase.sid == sid else { return }
        // Channel failures have their own recovery path. Re-registering replays this interest.
        await Self.acknowledge(
            authorised, via: transport,
            onHeaders: Self.onPingHeaders(pingURL: request.url, credentials: credentials),
            onFailure: { _ in }
        )
    }
}
