import ChatKit
import Foundation
import GChatBridgeCore

/// Task 3's question (`findings.md` §65.9, "Two readings fit every answer"):
/// does `list_topics`' `filter.anchor` page history back from a time, or does
/// every answer reach the newest topic regardless of what the anchor says?
/// The capture behind §65.9 could not tell the two readings apart - the
/// anchor was always the account's own read position, so no page in it ever
/// stopped short of the newest topic.
///
/// Every **pure** part of the anchor stage lives here, split out of
/// `SearchProbeReport.swift` for the same `file_length` reason
/// `APIProbeReport+History.swift` is its own file. The one part that touches
/// the network, `SearchProbeReport.appendAnchorStage(candidateHits:firstRawHit0:call:lines:)`,
/// stays in the main file instead: it needs `SearchCallContext`, which is
/// file-private there.
extension SearchProbeReport {
    /// The three labeled requests this stage sends, by their anchor's offset
    /// from the hit's own create time - `+1 µs` first (an anchor just past
    /// the hit, the convention `LocalBridgeBackend.readPositionOffsetMicroseconds`
    /// already uses for "this covers the message"), then exactly on it, then
    /// `-1 µs`, in case the hit is not returned at the first offset
    /// (`task-3-brief.md` step 3's "try … variants in the same run").
    static let anchorOffsetsMicroseconds: [Int64] = [1, 0, -1]

    static func label(forAnchorOffset offset: Int64) -> String {
        switch offset {
        case 1: "anchor +1µs"
        case 0: "anchor exact"
        case -1: "anchor -1µs"
        default: "anchor \(offset >= 0 ? "+" : "")\(offset)µs"
        }
    }

    // MARK: - Picking the hit the anchor is built from

    /// What the anchor stage sends `list_topics` for, and what it compares
    /// each answer against.
    struct AnchorPick: Sendable {
        let group: GroupId
        /// What every offset in `anchorOffsetsMicroseconds` is added to - the
        /// hit's own `createdAt` when one decoded, or 30 days before `now` in
        /// the fallback (`task-3-brief.md`'s amendment to step 2).
        let anchorTimeUsec: Int64
        /// `nil` only in the fallback, where no hit decoded at all, so there
        /// is no id a response's messages can be compared against.
        let hitMessageID: String?
        let hitCreatedAt: Date?
        let hitIsReply: Bool?
        /// One sentence for the report: which hit was picked, or that none
        /// decoded and hit 0's conversation was used instead.
        let source: String
    }

    /// The oldest hit by its own mapped `createdAt`, so the anchor reaches as
    /// far back as the probe can see. `nil` on an empty list.
    static func oldestHit(from hits: [ChatKit.Message]) -> ChatKit.Message? {
        hits.min { $0.createdAt < $1.createdAt }
    }

    /// `candidateHits` is every hit `SearchHitMapping.page(from:)` decoded
    /// across every page `appendSearches` sent (first page, second page,
    /// newest-first) - "the hits the probe's earlier stages received
    /// (newest-first pages included)", per the amendment. `firstRawHit0` is
    /// the very first page's first raw hit element (`JSONSerialization`'s
    /// `Any`), read only when nothing decoded.
    static func pickAnchor(
        candidateHits: [ChatKit.Message], firstRawHit0: Any?, now: Date = Date()
    ) -> AnchorPick? {
        if let oldest = oldestHit(from: candidateHits),
           let group = ChannelEventMapping.groupID(for: oldest.conversationID) {
            return AnchorPick(
                group: group,
                anchorTimeUsec: Microseconds.from(oldest.createdAt),
                hitMessageID: oldest.id.rawValue,
                hitCreatedAt: oldest.createdAt,
                hitIsReply: oldest.isReply,
                source: "oldest of \(candidateHits.count) decoded hit(s) across every page"
            )
        }
        guard let firstRawHit0, let group = fallbackGroupID(fromRawHit0: firstRawHit0) else { return nil }
        let anchor = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return AnchorPick(
            group: group,
            anchorTimeUsec: Microseconds.from(anchor),
            hitMessageID: nil,
            hitCreatedAt: nil,
            hitIsReply: nil,
            source: "fallback: no hit decoded on any page; hit 0's conversation, anchor 30 days before now"
        )
    }

    /// Hit 0's group reference (field 3, index 2), read directly rather than
    /// through `SearchHitMapping.message(from:)` - used only when every hit
    /// this run saw failed that mapping, which §65.8's capture never observed
    /// (302 of 302 hits had a readable group reference there).
    ///
    /// Delegates the actual match to `SearchHitMapping.groupReference(_:)`
    /// (made internal for exactly this, fix round 1 review finding 2), rather
    /// than a second copy of its prefix check: the first copy silently
    /// dropped that function's `items.count >= 3 && items[2] == 2` space
    /// requirement, which is one rule for what a group reference looks like
    /// split into two places that could (and did) disagree. Field 3 is
    /// always a direct index, far under the trailing-object cutoff at field
    /// 48, so no merge is needed to reach it here.
    static func fallbackGroupID(fromRawHit0 raw: Any) -> GroupId? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let value = try? PBLiteValue(json: data),
              let wrapper = value.arrayValue, let inner = wrapper.first,
              let innerItems = inner.arrayValue, innerItems.indices.contains(2)
        else { return nil }
        return SearchHitMapping.groupReference(innerItems[2])
    }

    // MARK: - One request's answer, summarized against its anchor

    /// Numbers and booleans only - never a message's id or text - so nothing
    /// built from this can be the thing that leaks one into a report pasted
    /// into `findings.md`.
    struct AnchorResponseSummary: Sendable, Hashable {
        let topicCount: Int
        let messageCount: Int
        let containsFirstTopic: Bool
        let containsLastTopic: Bool
        let minOffsetSeconds: Double?
        let maxOffsetSeconds: Double?
        let olderCount: Int
        let equalCount: Int
        let newerCount: Int
        /// `nil` only when `hitMessageID` was `nil` (the fallback pick).
        let hitIncluded: Bool?
        let topicOrder: String
        let reading: String
    }

    /// `response`'s `topics`/`replies`, measured against `anchorTimeUsec` -
    /// every number findings.md §65.9's "two readings" paragraph needs: how
    /// many topics and messages came back, whether the page reached either
    /// end, where each message's own create time sits relative to the
    /// anchor, whether the hit itself is among them, and the order the
    /// topics arrived in.
    static func summarize(
        response: ListTopicsResponse, anchorTimeUsec: Int64, hitMessageID: String?
    ) -> AnchorResponseSummary {
        let messages = response.topics.flatMap(\.replies)
        let offsetsSeconds = messages.map { Double($0.createTime - anchorTimeUsec) / 1_000_000 }
        let topicOrder = anchorTopicOrder(response.topics.map(\.createTimeUsec))
        let reading = anchorReading(
            containsFirstTopic: response.containsFirstTopic,
            containsLastTopic: response.containsLastTopic,
            offsetsSeconds: offsetsSeconds
        )
        return AnchorResponseSummary(
            topicCount: response.topics.count,
            messageCount: messages.count,
            containsFirstTopic: response.containsFirstTopic,
            containsLastTopic: response.containsLastTopic,
            minOffsetSeconds: offsetsSeconds.min(),
            maxOffsetSeconds: offsetsSeconds.max(),
            olderCount: offsetsSeconds.count(where: { $0 < 0 }),
            equalCount: offsetsSeconds.count(where: { $0 == 0 }),
            newerCount: offsetsSeconds.count(where: { $0 > 0 }),
            hitIncluded: hitMessageID.map { id in messages.contains { $0.id.messageID == id } },
            topicOrder: topicOrder,
            reading: reading
        )
    }

    /// "ascending"/"descending"/"mixed" by creation, the same comparison
    /// `appendNewestFirst`'s own `times == times.sorted(by: >)` already uses.
    /// findings.md §65.9 found topics ascending by `create_time_usec` on 28
    /// of 28 without this filter; this is what tells whether the filter
    /// changes that.
    static func anchorTopicOrder(_ createTimesUsec: [Int64]) -> String {
        guard createTimesUsec.count > 1 else { return "n/a (\(createTimesUsec.count) topic)" }
        if createTimesUsec == createTimesUsec.sorted() {
            return "ascending"
        }
        if createTimesUsec == createTimesUsec.sorted(by: >) {
            return "descending"
        }
        return "mixed"
    }

    /// The decisive reading `task-3-brief.md`'s amendment states in full: "if
    /// `contains_last_topic` is false and every returned time is at or
    /// before the anchor, the filter pages (inclusive); if it is true, it
    /// does not." A false `contains_last_topic` with a message *after* the
    /// anchor fits neither half, so it is reported as such rather than forced
    /// into one - that combination is not something either reading predicts.
    ///
    /// **Checked before any of that**: a small conversation that comes back
    /// whole - `containsFirstTopic` *and* `containsLastTopic` both true - is
    /// not evidence either way. Both readings predict exactly that answer (a
    /// page that pages back from the anchor and a page that always reaches
    /// the newest topic are indistinguishable once the whole conversation
    /// fits in one page), so reading it as "does not page" would be a verdict
    /// from something that never measured the question (fix round 1, review
    /// finding 1). Only `containsLastTopic` true on its own - the page
    /// reached the newest topic without reaching the oldest one - is real
    /// asymmetric evidence and still reads "does not page".
    static func anchorReading(
        containsFirstTopic: Bool, containsLastTopic: Bool, offsetsSeconds: [Double]
    ) -> String {
        if containsFirstTopic, containsLastTopic {
            return "inconclusive: the whole conversation came back in one page"
        }
        if containsLastTopic {
            return "does not page (contains_last_topic true)"
        }
        guard !offsetsSeconds.isEmpty else { return "inconclusive (no messages returned)" }
        return offsetsSeconds.allSatisfy { $0 <= 0 }
            ? "pages, inclusive (contains_last_topic false, every time at or before the anchor)"
            : "inconclusive (contains_last_topic false, but a time is after the anchor)"
    }

    // MARK: - Rendering

    /// The stage's own knobs, named once so the owner's paste says what was
    /// actually sent without repeating it on every one of the three labeled
    /// requests.
    static func anchorConfigLine(request: ListTopicsRequest) -> String {
        "config: offsets \(anchorOffsetsMicroseconds.map(String.init).joined(separator: "/")) µs, "
            + "sort_option 2, page_size_for_topics \(request.pageSizeForTopics), "
            + "page_size_for_replies \(request.pageSizeForReplies)"
    }

    /// One labeled request's report lines. Numbers and booleans from
    /// `summary` only - see its own doc comment.
    static func anchorReportLines(label: String, summary: AnchorResponseSummary) -> [String] {
        let minText = summary.minOffsetSeconds.map { String(format: "%.3f", $0) } ?? "-"
        let maxText = summary.maxOffsetSeconds.map { String(format: "%.3f", $0) } ?? "-"
        let hitText = summary.hitIncluded.map { $0 ? "yes" : "no" } ?? "n/a (fallback anchor, no hit id)"
        return [
            "  \(label):",
            "    topics: \(summary.topicCount), messages: \(summary.messageCount)",
            "    contains_first_topic: \(summary.containsFirstTopic), "
                + "contains_last_topic: \(summary.containsLastTopic)",
            "    message time vs anchor (s): min \(minText), max \(maxText); "
                + "older \(summary.olderCount), equal \(summary.equalCount), newer \(summary.newerCount)",
            "    hit's message id among returned: \(hitText)",
            "    topic order by create time: \(summary.topicOrder)",
            "    reading: \(summary.reading)"
        ]
    }
}
