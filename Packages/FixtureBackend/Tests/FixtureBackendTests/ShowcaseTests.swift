import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

@Suite(.timeLimit(.minutes(1)))
struct ShowcaseTests {
    @Test func everyConversationHasConsistentHistoryAndMembership() throws {
        let world = FixtureWorld.showcase
        #expect(world.inconsistencies().isEmpty)
        #expect(Set(world.messages.map(\.id)).count == world.messages.count)
        #expect(Set(world.conversations.map(\.id)).count == world.conversations.count)
        for conversation in world.conversations {
            let messages = world.messages(in: conversation.id)
            #expect(messages.count >= 2)
            #expect(messages.allSatisfy { conversation.members.contains($0.sender) })
            #expect(conversation.lastActivity == messages.map(\.createdAt).max())
            let main = messages.filter { !$0.isReply }
            #expect(conversation.latestMainMessageAt == main.map(\.createdAt).max())
            #expect(conversation.hasUnreadThread == world.hasUnreadThread(in: conversation.id))
            if conversation.hasUnread {
                let read = try #require(conversation.readPosition)
                #expect(main.contains { $0.createdAt > read && $0.sender != world.me })
            }
        }
    }

    @Test func mentionsAndLinksStayInsideTheirActualText() throws {
        let world = FixtureWorld.showcase
        let mentions = world.messages.filter { $0.mentionsMe(world.me) }
        #expect(mentions.count >= 3)
        for message in world.messages {
            let text = message.text as NSString
            for mention in message.mentions {
                try #require(mention.start >= 0 && mention.length > 0)
                try #require(mention.start + mention.length <= text.length)
                #expect(text.substring(with: NSRange(location: mention.start, length: 1)) == "@")
            }
            for link in message.links {
                if let start = link.start, let length = link.length {
                    #expect(start >= 0 && length > 0 && start + length <= text.length)
                }
            }
        }
    }

    @Test func meetingProjectionAndFollowedThreadsHaveRealContent() throws {
        let world = FixtureWorld.showcase
        let previous = try #require(world.conversation(Showcase.standupPrevious)?.meeting)
        let latest = try #require(world.conversation(Showcase.standup)?.meeting)
        #expect(previous.isValid && latest.isValid)
        #expect(previous.seriesID == latest.seriesID)
        #expect(previous.occurrenceID != latest.occurrenceID)
        #expect(previous.scheduledStart < latest.scheduledStart)
        #expect(world.conversation(Showcase.oneOff)?.meeting == nil)
        #expect(world.unreadReplies(in: .init("showcase/board"), of: Showcase.design) == 1)
        #expect(world.unreadReplies(in: .init("showcase/checklist"), of: Showcase.launch) == 1)
    }

    @Test func previewOriginalAndDownloadedFilesAgree() async throws {
        let world = FixtureWorld.showcase
        let backend = FakeBackend(world: world)
        let attachments = Set(world.messages.flatMap(\.attachments))
        #expect(attachments.count == 4)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("showcase-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for attachment in attachments {
            let preview = try await backend.attachmentData(attachment, size: .preview)
            let original = try await backend.attachmentData(attachment, size: .original)
            #expect(preview == original)
            #expect(original.count == attachment.byteSize)
            if attachment.isImage {
                #expect(Array(original.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
                #expect(pngDimension(original, offset: 16) == attachment.width)
                #expect(pngDimension(original, offset: 20) == attachment.height)
            } else if attachment.contentType == "application/pdf" {
                #expect(original.starts(with: Data("%PDF-1.4".utf8)))
                #expect(String(decoding: original, as: UTF8.self).contains("/Count 1"))
            } else {
                #expect(String(decoding: original, as: UTF8.self).contains("Juniper autumn launch"))
            }
            let destination = directory.appendingPathComponent(attachment.name)
            try await backend.downloadAttachment(attachment, to: destination) { _ in }
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    @Test func bundledPreviewsAreDistinctAndForeignHostsRemainRefused() async throws {
        let backend = FakeBackend(world: .showcase)
        let launch = try await backend.remoteImage(
            #require(URL(string: "https://media.acme.example/showcase/launch-preview.png"))
        )
        let board = try await backend.remoteImage(
            #require(URL(string: "https://media.acme.example/showcase/studio-board.png"))
        )
        #expect(launch != board)
        #expect(launch != FixtureImage.png)
        #expect(pngDimension(launch, offset: 16) == 1200)
        #expect(pngDimension(launch, offset: 20) == 630)
        await #expect(throws: (any Error).self) {
            try await backend.remoteImage(
                #require(URL(string: "https://unrelated.example/showcase/launch-preview.png"))
            )
        }
        await #expect(throws: (any Error).self) {
            try await backend.attachmentData(Attachment(
                id: "showcase/not-held", name: "Unknown.png", contentType: "image/png"
            ), size: .original)
        }
    }

    @Test func scriptIsDeterministicAndDoesNotGrowTheScreenshotTranscript() async throws {
        let first = FakeBackend(world: .showcase)
        let second = FakeBackend(world: .showcase)
        let firstEvents = EventCollector(first.events)
        let secondEvents = EventCollector(second.events)
        for backend in [first, second] {
            try await backend.connect()
            try await backend.play(.showcaseDemo)
        }
        let count = await first.emittedCount
        let lhs = await firstEvents.next(count)
        let rhs = await secondEvents.next(count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(lhs) == encoder.encode(rhs))
        #expect(await first.currentWorld == FixtureWorld.showcase)
        #expect(lhs.contains {
            if case .readReceiptsChanged = $0 {
                true
            } else {
                false
            }
        })
        #expect(lhs.contains {
            if case .scopedTypingChanged = $0 {
                true
            } else {
                false
            }
        })
    }

    private func pngDimension(_ data: Data, offset: Int) -> Int {
        data[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
}
