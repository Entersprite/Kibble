import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// People outside a group chat, and in a thread's composer (mention
/// non-members spec §2, beyond spaces).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OutsideMentionsTests {
    static let outsider = DirectorySearchTests.outsider
    /// Listed by the group chat, with no name: never a mention candidate.
    static let quiet = Member(id: Member.ID("fixture-quiet"), kind: .human, email: "quiet@example.invalid")
    static let quinn = Member(id: Member.ID("quinn"), kind: .human, displayName: "Quinn Out")
    static let group = Conversation.ID("group:1")
    static let space = Conversation.ID("space:1")
    static let thread = MessageThread.ID("fixture-seed-topic-3")

    /// The minimal world plus a group chat of three, one of them nameless.
    static var world: FixtureWorld {
        var world = FixtureWorld.minimal
        world.members.append(quiet)
        world.conversations.append(Conversation(
            id: group, kind: .groupDirectMessage, lastActivity: world.startedAt,
            members: [world.me, Member.ID("fixture-other"), quiet.id]
        ))
        return world
    }

    static func backend(
        capabilities: Capabilities = .fixture,
        directory: [Member] = [outsider]
    ) -> RecordingBackend {
        RecordingBackend(world: world, capabilities: capabilities, directory: directory)
    }

    static func mentioning(_ people: [Member]) -> ComposedMessage {
        var text = ""
        var mentions: [Mention] = []
        for person in people {
            let name = "@" + (person.displayName ?? "")
            mentions.append(Mention(
                target: .user(person.id),
                start: (text as NSString).length,
                length: (name as NSString).length
            ))
            text += name + " "
        }
        return ComposedMessage(text: text + "hello", mentions: mentions)
    }

    private static func sent(_ backend: RecordingBackend) async -> [String] {
        await backend.commands.compactMap {
            if case let .sendMessage(_, _, text, _, _, _, _) = $0 {
                text
            } else {
                nil
            }
        }
    }

    // MARK: - Where outsiders are offered

    @Test func spacesAndGroupChatsOfferOutsidersAndOneToOneMessagesDoNot() {
        #expect(ChatSessionModel.offersOutsiders(in: .space))
        #expect(ChatSessionModel.offersOutsiders(in: .groupDirectMessage))
        #expect(!ChatSessionModel.offersOutsiders(in: .directMessage))
        #expect(!ChatSessionModel.offersOutsiders(in: .appDirectMessage))
    }

    @Test func theSelectionSaysWhetherItsComposersOfferOutsiders() async throws {
        let model = try await DirectorySearchTests.model(Self.backend(), select: Self.group.rawValue)
        #expect(model.offersOutsideMentions)
        model.select(Conversation.ID("dm:1"))
        await settleAutoMarkRead()
        #expect(!model.offersOutsideMentions)
        await model.stop()
    }

    @Test func noOutsidersWithoutTheCapability() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canMentionNonMembers = false
        let backend = Self.backend(capabilities: capabilities)
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        #expect(!model.offersOutsideMentions)
        model.directoryQuery("out")
        await settleAutoMarkRead()
        #expect(await backend.searches.isEmpty)
        await model.stop()
    }

    // MARK: - The directory in a group chat

    @Test func aGroupChatSearchesTheDirectory() async throws {
        let model = try await DirectorySearchTests.model(Self.backend(), select: Self.group.rawValue)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        #expect(model.directoryResults.map(\.id) == [Self.outsider.id])
        await model.stop()
    }

    /// Two composers can each have an `@` open, so the results say which
    /// query they answer.
    @Test func theResultsCarryTheQueryTheyAnswer() async throws {
        let model = try await DirectorySearchTests.model(Self.backend(), select: Self.group.rawValue)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        #expect(model.directoryResultsQuery == "out")
        model.directoryQuery(nil)
        #expect(model.directoryResultsQuery == nil)
        await model.stop()
    }

    /// Quinn is the positive control: the same query finds both.
    @Test func someoneTheGroupChatListsIsNeverADirectoryResult() async throws {
        let backend = Self.backend(directory: [Self.quiet, Self.quinn])
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        model.directoryQuery("qu")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        #expect(model.directoryResults.map(\.id) == [Self.quinn.id])
        await model.stop()
    }

    // MARK: - Who is outside, and how they can be added

    @Test func aGroupChatOutsiderIsAddedBeforeSending() async throws {
        let model = try await DirectorySearchTests.model(Self.backend(), select: Self.group.rawValue)
        model.checkMembership(Self.outsider.id)
        let found = await model.nonMembers(in: Self.mentioning([Self.outsider]))
        #expect(found == NonMembers(people: [Self.outsider.id], adding: .beforeSending))
        await model.stop()
    }

    @Test func withoutTheGroupChatsDetailsNobodyCanBeAdded() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canReadConversationDetails = false
        let model = try await DirectorySearchTests.model(
            Self.backend(capabilities: capabilities), select: Self.group.rawValue
        )
        model.checkMembership(Self.outsider.id)
        let found = await model.nonMembers(in: Self.mentioning([Self.outsider]))
        #expect(found == NonMembers(people: [Self.outsider.id], adding: .unavailable))
        await model.stop()
    }

    /// The check is held past the wait, so only the group chat's own list
    /// can say they are in it. The outsider, held the same way, is the
    /// positive control.
    @Test func someoneTheGroupChatListsIsNeverANonMember() async throws {
        let backend = Self.backend(directory: [Self.quiet, Self.outsider])
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        await backend.holdMemberships(true)
        model.checkMembership(Self.quiet.id)
        model.checkMembership(Self.outsider.id)
        let found = await model.nonMembers(in: Self.mentioning([Self.quiet, Self.outsider]))
        #expect(found.people == [Self.outsider.id])
        await backend.releaseHeldMembership()
        await backend.releaseHeldMembership()
        await model.stop()
    }

    // MARK: - Add and Send in a group chat

    @Test func addAndSendAddsThemAndThenSends() async throws {
        let backend = Self.backend()
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        let message = Self.mentioning([Self.outsider])
        model.addAndSend(message, adding: [Self.outsider.id], in: Self.group, thread: nil)
        await settleAutoMarkRead(until: "sent") { await Self.sent(backend) == [message.text] }
        #expect(await backend.mutations == [.addPeople([Self.outsider.id])])
        await settleAutoMarkRead(until: "they are a member") {
            model.mentionCandidates.contains { $0.id == Self.outsider.id }
        }
        await model.stop()
    }

    /// Nobody in the fixture's directory, so the add fails for them.
    @Test func aRefusedAddSendsNothingAndGivesTheMessageBack() async throws {
        let backend = Self.backend()
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        let stranger = Member(id: Member.ID("stranger"), kind: .human, displayName: "Stranger")
        let message = Self.mentioning([stranger])
        model.addAndSend(message, adding: [stranger.id], in: Self.group, thread: nil)
        await settleAutoMarkRead(until: "the message comes back") { model.failedDraft == message }
        await settleAutoMarkRead(until: "the failure shows") { model.lastError != nil }
        #expect(await Self.sent(backend).isEmpty)
        await model.stop()
    }

    @Test func anUnconfirmedAddSendsNothing() async throws {
        let backend = Self.backend()
        await backend.leaveMutationsUnconfirmed(true)
        let model = try await DirectorySearchTests.model(backend, select: Self.group.rawValue)
        let message = Self.mentioning([Self.outsider])
        model.addAndSend(message, adding: [Self.outsider.id], in: Self.group, thread: nil)
        await settleAutoMarkRead(until: "the message comes back") { model.failedDraft == message }
        #expect(await Self.sent(backend).isEmpty)
        #expect(await backend.mutations.count == 1)
        await model.stop()
    }

    // MARK: - The thread's composer

    @Test func aThreadReplyAddedAndSentGoesIntoItsThread() async throws {
        let backend = Self.backend()
        let model = try await DirectorySearchTests.model(backend)
        model.openThread(Self.thread)
        let message = Self.mentioning([Self.outsider])
        model.addAndSend(message, adding: [Self.outsider.id], in: Self.space, thread: Self.thread)
        await settleAutoMarkRead(until: "sent") { await Self.sent(backend) == [message.text] }
        let threads = await backend.commands.compactMap {
            if case let .sendMessage(_, thread, _, _, _, _, _) = $0 {
                thread
            } else {
                nil
            }
        }
        #expect(threads == [Self.thread])
        await model.stop()
    }

    @Test func aReplyForAThreadNoLongerOpenGoesBackToThatThread() async throws {
        let backend = Self.backend()
        let model = try await DirectorySearchTests.model(backend)
        model.openThread(Self.thread)
        model.closeThread()
        let message = ComposedMessage(text: "meant for the thread")
        model.sendReply(message, in: Self.space, thread: Self.thread)
        await settleAutoMarkRead()
        #expect(await Self.sent(backend).isEmpty)
        model.openThread(Self.thread)
        #expect(model.failedReplyDraft == message)
        await model.stop()
    }

    @Test func aReplyForTheOpenThreadIsPosted() async throws {
        let backend = Self.backend()
        let model = try await DirectorySearchTests.model(backend)
        model.openThread(Self.thread)
        model.sendReply(ComposedMessage(text: "in the thread"), in: Self.space, thread: Self.thread)
        await settleAutoMarkRead(until: "posted") { await Self.sent(backend) == ["in the thread"] }
        await model.stop()
    }

    @Test func aKeptReplyComesBackToItsThread() async throws {
        let model = try await DirectorySearchTests.model(Self.backend())
        model.openThread(Self.thread)
        model.keepReplyDraft(ComposedMessage(text: "unsent"), in: Self.space, thread: Self.thread)
        #expect(model.failedReplyDraft == ComposedMessage(text: "unsent"))
        await model.stop()
    }
}
