import Foundation

public extension ChannelSession {
    /// Retain one local receive interest across channel registration/reconnect.
    /// Nil forgets it locally; the protocol has no verified unsubscribe operation.
    func watchGroup(_ group: GroupId?) async {
        await watchGroups(group.map { [$0] } ?? [])
    }

    /// Retain the union of receive interests. Removing an interest is local;
    /// a fresh channel registration replays only the current set.
    func watchGroups(_ groups: [GroupId]) async {
        guard !Task.isCancelled, !state.phase.isTerminal else { return }
        let unique = groups.reduce(into: [GroupId]()) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
        guard unique != groupInterest.groups else { return }
        groupInterest.groups = unique
        groupInterest.revision = UUID()
        await sendGroupSubscription()
    }
}

extension ChannelSession {
    var watchedGroups: [GroupId] {
        groupInterest.groups
    }

    var watchedGroup: GroupId? {
        groupInterest.groups.first
    }

    func prepareGroupSubscription(sid: String) async {
        guard !Task.isCancelled, state.phase.sid == sid else { return }
        groupInterest.readySID = sid
        await sendGroupSubscription()
    }

    private func sendGroupSubscription() async {
        guard !Task.isCancelled, let sid = state.phase.sid,
              groupInterest.readySID == sid else { return }
        let revision = groupInterest.revision
        for group in groupInterest.groups {
            guard !Task.isCancelled, revision == groupInterest.revision,
                  state.phase.sid == sid else { return }
            requestIdentifier += 1
            let ofs = streamEventOfs
            streamEventOfs += 1
            guard let request = requests.subscribe(
                group: group, sid: sid, aid: state.highestProcessedAid, rid: requestIdentifier, ofs: ofs
            ) else { continue }
            let authorised = await credentials.authorisingChannel(request)
            guard !Task.isCancelled, revision == groupInterest.revision,
                  state.phase.sid == sid else { return }
            await Self.sendControl(
                authorised, via: transport,
                onHeaders: Self.onPingHeaders(pingURL: request.url, credentials: credentials),
                onFailure: { _ in }
            )
        }
    }
}

struct ChannelGroupInterest {
    var groups: [GroupId] = []
    var revision = UUID()
    var readySID: String?
}
