import Foundation
import GChatBridgeCore

/// One cancellable Meet prefix subscription. No media/device/invitation RPC
/// is performed here. Each delivery is checked against its original account.
enum MeetIncomingWatch {
    enum Event: Sendable {
        case opened
        case notification(MeetPushWire.Event)
        case failed(String)
        case diagnostic(String)
    }

    struct Settings: Sendable {
        let sleep: @Sendable (Duration) async throws -> Void
        let zx: @Sendable () -> String
        static let live = Settings(sleep: { try await Task.sleep(for: $0) }, zx: { UUID().uuidString })
    }

    static func run(
        requests: PunctualRequests, topic: PunctualTopic, client: PunctualClient,
        settings: Settings = .live,
        validate: @escaping @Sendable () async throws -> Void,
        receive: @escaping @Sendable (Event) async -> Void
    ) async {
        do {
            let context = Context(
                requests: requests,
                client: client,
                settings: settings,
                validate: validate,
                receive: receive
            )
            let channel = try await context.open(topic)
            var aid = channel.aid
            var emptyRun = 0
            while !Task.isCancelled {
                let count = try await context.poll(channel.id, aid: &aid)
                emptyRun = count == 0 ? min(emptyRun + 1, 5) : 0
                try await settings.sleep(.seconds(1 << emptyRun))
            }
        } catch {
            guard !Task.isCancelled else { return }
            await receive(.failed(safeError(error)))
        }
    }

    private enum Failure: Error {
        case http(Int), framing, ended, subscription(Int?)
    }

    private static func safeError(_ error: any Error) -> String {
        switch error {
        case let Failure.http(status): "Meet watch returned HTTP \(status)."
        case Failure.framing: "Meet watch response framing was invalid."
        case Failure.ended: "Meet watch was closed by the server. Restart listening."
        case let Failure.subscription(code): "Meet watch subscription ended; service code "
            + "\(code.map(String.init) ?? "unknown")."
        case PunctualClientError.missingSessionProof: "Meet watch has no scoped session proof."
        case MeetDMCallTrialError.accountChanged: "The Chat account changed. Reload people."
        default: "Meet watch failed. Restart listening."
        }
    }

    private struct Context: Sendable {
        let requests: PunctualRequests
        let client: PunctualClient
        let settings: Settings
        let validate: @Sendable () async throws -> Void
        let receive: @Sendable (Event) async -> Void

        func open(_ topic: PunctualTopic) async throws -> (id: PunctualChannelID, aid: Int) {
            try await check()
            var choose = try requests.chooseServer(topic)
            choose.followsRedirects = false
            choose.maxBodyBytes = 1_000_000
            let chosen = try await client.send(choose)
            try await check()
            guard chosen.status == 200 else { throw Failure.http(chosen.status) }
            let session = try PunctualAnswers.gsessionID(inChooseServer: chosen.body)
            var opening = try requests.open(
                gsessionID: session, rid: 1, zx: settings.zx(), watch: PunctualWatch(
                    sequence: 1,
                    topic: topic
                )
            )
            opening.followsRedirects = false
            opening.maxBodyBytes = 1_000_000
            let opened = try await client.send(opening)
            try await check()
            guard opened.status == 200 else { throw Failure.http(opened.status) }
            let arrays = try openingArrays(opened.body)
            let initial = opened.headers["x-http-initial-response"]
            let sid = try initial.map { try ChannelChunk.sid(inInitialResponse: $0) }
                ?? arrays.compactMap { array -> String? in
                    guard let fields = array.data.arrayValue, fields.count >= 2,
                          fields[0].stringValue == "c" else { return nil }
                    return fields[1].stringValue
                }.first
            guard let sid, !sid.isEmpty else { throw Failure.framing }
            await receive(.opened)
            var aid = 0
            for array in arrays {
                try await deliver(array, aid: &aid)
            }
            return (PunctualChannelID(gsessionID: session, sid: sid), aid)
        }

        private func openingArrays(_ body: Data) throws -> [ChannelArray] {
            if body.first == UInt8(ascii: "[") {
                return try ChannelChunk.arrays(in: String(decoding: body, as: UTF8.self))
            }
            var parser = ChunkParser()
            let chunks = try parser.chunks(from: body)
            guard parser.bufferedByteCount == 0 else { throw Failure.framing }
            return try chunks.flatMap { try ChannelChunk.arrays(in: $0) }
        }

        func poll(_ channel: PunctualChannelID, aid: inout Int) async throws -> Int {
            try await check()
            var request = requests.poll(on: channel, aid: aid, zx: settings.zx())
            request.timeout = .seconds(70)
            request.maxBodyBytes = 1_000_000
            request.followsRedirects = false
            do {
                await receive(.diagnostic("Meet watch: polling"))
                let stream = try await client.stream(request)
                try await check()
                await receive(.diagnostic("Meet watch: poll HTTP \(stream.status)"))
                guard stream.status == 200 else { throw Failure.http(stream.status) }
                var parser = ChunkParser()
                var count = 0
                for try await bytes in stream.body {
                    try await check()
                    guard parser.bufferedByteCount + bytes.count <= 1_000_000 else { throw Failure.framing }
                    for chunk in try parser.chunks(from: bytes) {
                        for array in try ChannelChunk.arrays(in: chunk) {
                            try await deliver(array, aid: &aid)
                            count += 1
                        }
                    }
                }
                try await check()
                guard parser.bufferedByteCount == 0 else { throw Failure.framing }
                return count
            } catch let failure as ClassifiedTransportFailure {
                try await check()
                // An idle long poll can time out on a healthy subscription. A lost
                // connection must reopen the subscription with a fresh channel.
                guard failure.reason == .timedOut else { throw failure }
                return 0
            }
        }

        private func deliver(_ array: ChannelArray, aid: inout Int) async throws {
            try await check()
            guard array.aid >= 0 else { throw Failure.framing }
            guard array.aid > aid || array.aid == 0 else { return }
            if array.data == ["stop"] || array.data == ["close"] {
                throw Failure.ended
            }
            let events = try MeetPushWire.events(in: array.data)
            if !array.isKeepalive {
                await receive(.diagnostic(
                    "Meet watch: " + MeetPushWire.envelopeSummary(array.data)
                        + "; decoded \(events.count) events"
                ))
            }
            for event in events {
                if case let .stopped(code) = event {
                    throw Failure.subscription(code)
                }
                try await check()
                await receive(.notification(event))
            }
            aid = max(aid, array.aid)
        }

        private func check() async throws {
            try Task.checkCancellation()
            try await validate()
            try Task.checkCancellation()
        }
    }
}
