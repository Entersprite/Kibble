import ChatKit
import Foundation
import GChatBridgeCore

/// `searchMessages(_:after:)` - `SBNmJb` over `batchexecute`, made real.
/// `SearchProbeReport` already proved Google accepts a request Kibble built
/// itself end to end (`findings.md` §65.7: HTTP 200,
/// no error code, `at` from `SNlM0e`, no extension header, no `/u/0`); this
/// reaches the exact same request from the seam instead of a probe, and maps
/// every hit through `SearchHitMapping`, the pure function `--probe=search`'s
/// own anchor stage already shares.
///
/// A search is never written to the store here - the spec's own rule, and
/// why this file never imports anything that touches one.
public extension LocalBridgeBackend {
    func searchMessages(
        _ query: MessageSearchQuery,
        after cursor: MessageSearchCursor?
    ) async throws -> MessageSearchPage {
        guard isConnected else {
            throw ChatError.unknown("searchMessages requires connect() to succeed first")
        }
        // Never captured on the wire (`findings.md` §65.5): refusing rather
        // than silently dropping it is the plan's own ruling, the same
        // posture `membership(of:in:)` and `searchPeople` take toward a
        // filter or a conversation they cannot honour.
        guard query.newerThan == nil else {
            throw ChatError.unsupported(capability: "messageSearchFilters: newerThan")
        }
        let page = try decodedPage(for: cursor, matching: query)
        guard let context = bootstrapWiz.flatMap({ BatchExecuteContext($0) }) else {
            throw ChatError.unknown(
                "the Chat shell lacks SNlM0e, FdrFJe or cfb2h - a batchexecute call needs all three"
            )
        }
        let searchPayload = try await searchPayload(for: query, page: page)
        let request = BatchExecute.request(
            BatchExecuteCall(
                rpc: SearchRequests.rpc,
                payload: SearchRequests.payload(searchPayload),
                sourcePath: SearchRequests.sourcePath
            ),
            context: context,
            requestID: nextSearchRequestID(),
            endpoints: endpoints,
            // Rung A, with no extension header, is what §65.7's probe run
            // found Google accepts; there is no rung B here because nothing
            // has ever shown it is needed.
            sendsExtensionHeader: false
        )
        // No do/catch around the send itself, the same shape `searchPeople`
        // takes: a transport failure (including a cancelled task's
        // `CancellationError`) propagates exactly as thrown, rather than
        // being folded into a `ChatError` that would hide which one it was.
        let response = try await PunctualClient(transport: transport, credentials: credentials)
            .send(request)
        // The send above does not itself check cancellation - a transport is
        // free to honour it or not, so a task cancelled while the request was
        // in flight can still land here with a perfectly good answer. Nothing
        // past this point should run for a caller who has already stopped
        // listening - most of all `resolveUnknownMembers` below, which would
        // otherwise start a `get_members` call nobody asked for any more.
        try Task.checkCancellation()
        guard response.status == 200 else {
            throw ChatError.server(status: response.status, message: "the search batchexecute call")
        }
        let inner = try decodedAnswer(in: response)
        let mapped = SearchHitMapping.page(from: inner)
        SearchLog.page(hits: mapped.hits.count, dropped: mapped.dropped, hasNext: mapped.next != nil)
        // A hit's time is its own microseconds (`findings.md` §65.8), so an
        // opened hit's history can anchor on it (`loadMessages(in:before:)`).
        messageTimes.remember(mapped.hits)
        // Started, not awaited - the same rule `loadMessages(in:before:)`
        // follows for its own lookup, and for the same reason: a hit carries
        // no sender name (`findings.md` §65.8), so without this every result
        // would show a raw id until something else happened to look the
        // sender up. `resolveUnknownMembers` already no-ops once `apiClient`
        // is `nil`, which is what makes this safe to call even when
        // `disconnect()` ran while the request above was in flight.
        resolveUnknownMembers(mapped.hits.map(\.sender))
        let next = mapped.next.map { token in
            SearchCursorCoding.encode(
                SearchCursorPayload(
                    queryID: searchPayload.queryID, pageToken: token,
                    queryFingerprint: SearchCursorCoding.fingerprint(of: query)
                )
            )
        }
        return MessageSearchPage(hits: mapped.hits, next: next)
    }

    /// `_reqid`: a counter on the actor, mirroring the probe's own
    /// `SearchCallContext.nextRequestID()` (§65.6: "a fixed base plus 100,000
    /// per call").
    private func nextSearchRequestID() -> Int {
        searchRequestID += 100_000
        return searchRequestID
    }

    /// `nil` for a first page. For a later one, the cursor this backend's own
    /// previous page handed back - refused, never guessed at, when it will
    /// not decode or when it was built for a different query (§65.2: a page
    /// has to resend its query's own id and every filter, so mixing the two
    /// up would silently start answering one search with another's scope).
    private func decodedPage(
        for cursor: MessageSearchCursor?,
        matching query: MessageSearchQuery
    ) throws -> SearchCursorPayload? {
        guard let cursor else { return nil }
        guard let decoded = SearchCursorCoding.decode(cursor) else {
            throw ChatError.unknown("not a search cursor this backend made")
        }
        guard decoded.queryFingerprint == SearchCursorCoding.fingerprint(of: query) else {
            throw ChatError.unknown("this cursor was made for a different search query")
        }
        return decoded
    }

    /// The wire payload for one page: `queryID`/`pageToken`/`clientMillis`
    /// from `page` when there is one (§65.2: a new id only on a first page),
    /// and every filter §65.5's capture isolated, translated from the
    /// domain's ids the same way every other request in this backend is -
    /// `ChannelEventMapping.groupID(for:)` undoes `Conversation.ID`'s prefix,
    /// never a hand-rolled parse.
    private func searchPayload(
        for query: MessageSearchQuery,
        page: SearchCursorPayload?
    ) async throws -> MessageSearchPayload {
        var mentionsUserID: String?
        if query.mentionsMe {
            // `resolveAndEmitSelf()` may still be in flight (it runs behind
            // `connect()`, not awaited by it): wait for it the way the
            // calendar poll does (`startCalendarPoll(for:after:)`) rather
            // than refusing on a race `connect()` itself never promised to
            // have settled.
            await selfIdentification?.value
            guard let me = calendarPoll.me, !me.rawValue.isEmpty else {
                throw ChatError.unknown(
                    "searchMessages needs the local user's id for \"mentions me\", and "
                        + "get_self_user_status has not answered yet"
                )
            }
            mentionsUserID = me.rawValue
        }
        return try MessageSearchPayload(
            text: query.text,
            queryID: page?.queryID ?? SearchRequests.newQueryID(),
            pageToken: page?.pageToken,
            newestFirst: query.order == .newest,
            // Only on a later page (§65.2: "a 13-digit number on later pages
            // only").
            clientMillis: page == nil ? nil : Int64(Date().timeIntervalSince1970 * 1000),
            fromUserID: query.from?.rawValue,
            olderThanMicros: query.olderThan.map(Microseconds.from),
            hasFile: query.hasFile,
            hasLink: query.hasLink,
            mentionsUserID: mentionsUserID,
            conversationSpaceID: conversationSpaceID(for: query.conversation)
        )
    }

    /// `nil` for no conversation filter; a space's raw id for one; a throw
    /// for a direct message - no DM "Said in" was ever captured
    /// (`findings.md` §65.8), so this refuses rather than guessing its shape,
    /// the same posture `SearchHitMapping.groupReference(_:)` takes toward an
    /// unrecognised group reference coming the other way.
    private func conversationSpaceID(for conversationID: Conversation.ID?) throws -> String? {
        guard let conversationID else { return nil }
        guard let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown(
                "\(conversationID.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces"
            )
        }
        guard case let .spaceID(space) = group.id, !space.spaceID.isEmpty else {
            throw ChatError.unsupported(
                capability: "messageSearchFilters: conversation (a direct message - "
                    + "no DM \"Said in\" was ever captured on the wire)"
            )
        }
        return space.spaceID
    }

    /// `SBNmJb`'s own row out of the batchexecute answer: an error code, a
    /// missing payload, or a body that is not a batchexecute answer at all
    /// (an HTML sign-in page included - `CLAUDE.md`'s "auth failure returns
    /// HTTP 200") all become a `ChatError` here rather than reaching
    /// `JSONSerialization` on text that was never JSON.
    private func decodedAnswer(in response: HTTPResponse) throws -> [Any] {
        let answers: [BatchExecuteAnswer]
        do {
            answers = try BatchExecute.answers(in: response.body)
        } catch {
            throw ChatError.server(
                status: response.status,
                message: "the search batchexecute call answered a body that was not a batchexecute "
                    + "answer (possibly a sign-in page)"
            )
        }
        guard let answer = answers.first(where: { $0.rpc == SearchRequests.rpc }) else {
            throw ChatError.server(
                status: response.status, message: "no SBNmJb row in the batchexecute answer"
            )
        }
        if let code = answer.errorCode {
            throw ChatError.server(status: response.status, message: "SBNmJb answered error code \(code)")
        }
        guard let payload = answer.payload,
              let inner = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any]
        else {
            throw ChatError.server(
                status: response.status, message: "the SBNmJb row carried no decodable payload"
            )
        }
        return inner
    }
}
