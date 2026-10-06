import ChatKit
import Foundation
import GChatBridgeCore

/// The directory and membership, for mentioning people outside a space
/// (mention non-members spec §3.3).
public extension LocalBridgeBackend {
    /// `ListAutocompletions` on `people-pa`, keyed with the Punctual key and
    /// signed with `SAPISIDHASH` alone (`findings.md` §57.4). People only.
    func searchPeople(_ query: String) async throws -> [ChatKit.Member] {
        guard isConnected else {
            throw ChatError.unknown("searchPeople requires connect() to succeed first")
        }
        let key = try await peopleSearchKey()
        let jar = await credentials.snapshot?.cookies ?? []
        let input = SAPISIDHash.Input(
            cookies: jar,
            url: PeopleRequests.listAutocompletionsURL,
            origin: PeopleRequests.origin(of: endpoints),
            timestamp: Int(Date().timeIntervalSince1970)
        )
        let request = PeopleRequests.listAutocompletions(
            query: query,
            key: key,
            authorization: SAPISIDHash.authorization(.sapisidOnly, for: input, sha1: SHA1.hex),
            endpoints: endpoints
        )
        let response = try await PunctualClient(transport: transport, credentials: credentials).send(request)
        guard response.status == 200 else {
            throw ChatError.server(
                status: response.status,
                message: "the people search answered \(response.status)"
            )
        }
        return PeopleRequests.people(from: response.body).map { person in
            ChatKit.Member(
                id: ChatKit.Member.ID(person.id),
                kind: .human,
                displayName: person.name,
                email: person.email.isEmpty ? nil : person.email,
                avatarURL: person.photoURL
            )
        }
    }

    /// `get_membership` for one person in one space (§58.3): joined is a
    /// member, any other state is not, and no row is "could not tell". A DM
    /// is never asked: its members come with the world.
    func membership(
        of member: ChatKit.Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        guard let apiClient, let group = ChannelEventMapping.groupID(for: conversation),
              case .spaceID = group.id else { return .unknown }
        let response: GetMembershipResponse
        do {
            response = try await apiClient.call(
                .getMembership, MembersRequests.getMembership(member: member.rawValue, group: group)
            )
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ get_membership call")
        }
        guard let row = response.memberships.first else { return .unknown }
        return row.membershipState == .memberJoined ? .member : .notMember
    }

    /// The Punctual key: the mole shell's, else `/app/home`'s, fetched once
    /// per session (§57.1). A key that cannot be found throws, and is
    /// reported once per session: the cached absence answers every later
    /// search before the report is reached.
    private func peopleSearchKey() async throws -> String {
        if let cached = peopleKey {
            if let cached {
                return cached
            }
            throw ChatError.unknown("no people search key this session")
        }
        var found = bootstrapWiz?.punctualKey
        if found == nil {
            let request = HTTPRequest(
                url: endpoints.base.appendingPathComponent("app").appendingPathComponent("home"),
                headers: HTTPHeaders([("User-Agent", endpoints.userAgent)]),
                traceLabel: "app-home"
            )
            let response = try? await PunctualClient(transport: transport, credentials: credentials)
                .send(request)
            found = response
                .flatMap { WizGlobalData(html: String(decoding: $0.body, as: UTF8.self))?.punctualKey }
        }
        peopleKey = .some(found)
        guard let found else {
            emit(.backendError(.unknown(
                "the people search key (Tzliq) was in neither the mole shell nor /app/home"
            )))
            throw ChatError.unknown("no people search key this session")
        }
        return found
    }
}
