import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=events`' tally: the channel half of the in-a-meeting spike.
@Suite(.timeLimit(.minutes(1)))
struct ChannelEventTallyTests: SenderResolutionFixtures {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// Index `i` is field `i + 1`, a trailing dictionary holds higher fields,
    /// ordinals show their value, and a string never does.
    @Test func aShapeNamesFieldsAndNeverText() {
        let body = PBLiteValue.array([
            .null,
            .number(.integer(5)),
            .string("In a meeting"),
            .array([.number(.integer(1)), .null, .number(.integer(3))]),
            .number(.integer(1_790_000_000)),
            .object(["40": .number(.integer(2))])
        ])
        let shape = ChannelEventTally.shape(of: body, depth: 4)
        #expect(shape == "2=5,3:s,4{1=1,3=3},5,40=2")
        #expect(!shape.contains("meeting"))
    }

    @Test func countsPerTypeAndCapsTheShapesListed() {
        var tally = ChannelEventTally()
        for number in 1 ... 9 {
            tally.record(type: 45, body: .array([.number(.integer(Int64(number)))]), at: at)
        }
        tally.record(type: nil, body: .array([]), at: at)

        let report = tally.report(startedAt: at, writtenAt: at, build: "test")

        #expect(report.contains("type 45 ("))
        #expect(report.contains("9 bodies"))
        #expect(report.contains("  other shapes: 1"))
        #expect(report.contains("type -1 (untagged): 1 bodies"))
        #expect(report.hasPrefix("kibble channel event tally - format 1"))
    }

    /// A channel event reaches the file. Deleting the hook in `deliver(_:)`
    /// turns this red.
    @Test func aChannelEventReachesTheFile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-events-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: []), names: Self.names,
            liveChunk: liveChunk(from: "u-2")
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        await backend.tallyEvents(to: file)
        try await backend.connect()
        _ = await log.settle()

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("type 6 ("))
        #expect(text.contains("1 bodies"))
        #expect(!text.contains("hi\""))
        await backend.disconnect()
    }
}
