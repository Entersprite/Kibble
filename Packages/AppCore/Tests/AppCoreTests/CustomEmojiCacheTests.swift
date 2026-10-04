import AppCore
import ChatKit
import Foundation
import Testing

/// Counts emoji fetches, and can hold them until released.
private actor EmojiRecorder {
    private(set) var calls: [String] = []
    private var failuresLeft = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func failNext(_ count: Int) {
        failuresLeft = count
    }

    func hold() {
        holding = true
    }

    func release() {
        holding = false
        for continuation in held {
            continuation.resume()
        }
        held = []
    }

    var heldCount: Int {
        held.count
    }

    func fetch(_ emoji: CustomEmojiRef) async throws -> Data {
        calls.append(emoji.id)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw ChatError.server(status: 503, message: "try later")
        }
        return Data("emoji/\(emoji.id)".utf8)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CustomEmojiCacheTests {
    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "t")

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "custom-emoji-cache-tests-\(UUID().uuidString)")
    }

    private static func cache(_ recorder: EmojiRecorder, directory: URL?) -> AttachmentCache {
        AttachmentCache(directory: directory, customEmojiFetch: { emoji in
            try await recorder.fetch(emoji)
        }, fetch: { attachment, _ in
            Data("attachment/\(attachment.id)".utf8)
        })
    }

    /// Bounded (`CLAUDE.md`: `.timeLimit` cannot stop a loop that never suspends).
    private static func waitUntilHeld(_ recorder: EmojiRecorder, count: Int) async throws {
        for _ in 0 ..< 1000 where await recorder.heldCount < count {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await recorder.heldCount >= count)
    }

    @Test func aSecondRequestIsAnsweredWithoutFetching() async throws {
        let recorder = EmojiRecorder()
        let cache = Self.cache(recorder, directory: Self.directory())
        let first = try await cache.customEmojiData(for: Self.parrot)
        let second = try await cache.customEmojiData(for: Self.parrot)
        #expect(first == Data("emoji/e-1".utf8))
        #expect(second == first)
        #expect(await recorder.calls == ["e-1"])
    }

    @Test func theDiskOutlivesTheInstance() async throws {
        let directory = Self.directory()
        _ = try await Self.cache(EmojiRecorder(), directory: directory).customEmojiData(for: Self.parrot)
        let recorder = EmojiRecorder()
        let reopened = Self.cache(recorder, directory: directory)
        #expect(try await reopened.customEmojiData(for: Self.parrot) == Data("emoji/e-1".utf8))
        #expect(await recorder.calls.isEmpty)
    }

    /// Review Focus 2: thirty capsules of one emoji, one fetch.
    @Test func simultaneousRequestsShareOneFetch() async throws {
        let recorder = EmojiRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: nil)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0 ..< 30 {
                group.addTask { try await cache.customEmojiData(for: Self.parrot) }
            }
            try await Self.waitUntilHeld(recorder, count: 1)
            await recorder.release()
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 30)
        #expect(await recorder.calls == ["e-1"])
    }

    /// Review Focus 5: a failure is not remembered; the next request fetches.
    @Test func aFailedFetchIsNotCached() async throws {
        let recorder = EmojiRecorder()
        await recorder.failNext(1)
        let cache = Self.cache(recorder, directory: Self.directory())
        await #expect(throws: ChatError.self) {
            _ = try await cache.customEmojiData(for: Self.parrot)
        }
        #expect(try await cache.customEmojiData(for: Self.parrot) == Data("emoji/e-1".utf8))
        #expect(await recorder.calls == ["e-1", "e-1"])
    }

    /// Review Focus 3: sign-out mid-fetch leaves nothing on disk and throws.
    @Test func anEraseDuringAFetchWritesNothing() async throws {
        let directory = Self.directory()
        let recorder = EmojiRecorder()
        await recorder.hold()
        let cache = Self.cache(recorder, directory: directory)
        let pending = Task { try await cache.customEmojiData(for: Self.parrot) }
        try await Self.waitUntilHeld(recorder, count: 1)
        await cache.erase()
        await recorder.release()
        await #expect(throws: AttachmentCache.Erased.self) {
            _ = try await pending.value
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    /// An emoji and an attachment that share an id are different entries.
    @Test func anEmojiNeverAnswersForAnAttachment() async throws {
        let cache = Self.cache(EmojiRecorder(), directory: Self.directory())
        let attachment = ChatKit.Attachment(id: "e-1", name: "e.png", contentType: "image/png")
        _ = try await cache.customEmojiData(for: Self.parrot)
        #expect(try await cache.data(for: attachment, size: .preview) == Data("attachment/e-1".utf8))
    }

    @Test func withoutAnEmojiFetchItRefuses() async {
        let cache = AttachmentCache(directory: nil) { _, _ in Data() }
        await #expect(throws: AttachmentCache.NoCustomEmojiFetch.self) {
            _ = try await cache.customEmojiData(for: Self.parrot)
        }
    }
}
