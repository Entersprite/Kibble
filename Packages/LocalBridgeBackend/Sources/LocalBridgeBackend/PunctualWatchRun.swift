import Foundation
import GChatBridgeCore

/// The report `--probe=punctual` is writing, rewritten to disk after every
/// line so a run that is killed keeps what it saw.
actor PunctualProbeLog {
    private(set) var lines: [String] = []
    private(set) var polls = 0
    private(set) var arrays = 0
    private(set) var keepalives = 0
    private(set) var shapeCounts: [String: Int] = [:]
    private let flush: @Sendable (String) -> Void

    init(flush: @escaping @Sendable (String) -> Void = { _ in }) {
        self.flush = flush
    }

    func append(_ line: String) {
        lines.append(line)
        flush(lines.joined(separator: "\n"))
    }

    func countPoll() {
        polls += 1
    }

    /// A keepalive is counted, not printed: the long poll carries one every
    /// few seconds and they would bury the pushes.
    func record(aid: Int, shape: String, isKeepalive: Bool, at offset: String) {
        arrays += 1
        if isKeepalive {
            keepalives += 1
            return
        }
        shapeCounts[PunctualWatchRun.collapsed(shape), default: 0] += 1
        append("  \(offset) aid=\(aid) \(shape)")
    }
}

/// Watches availability on Punctual and logs every push as its shape.
///
/// The handshake is the one `findings.md` §47 read out of Chat on the web:
/// `chooseServer` mints a `gsessionid`, the channel is opened carrying the
/// first watch, the rest follow in one request, and a long-poll GET carries
/// the pushes until the deadline. Every value that reaches the log goes
/// through `PunctualPushShape`, which masks by parsing.
enum PunctualWatchRun {
    struct Person: Sendable {
        let id: String
        let label: String
    }

    /// Everything a test must control and the probe otherwise randomises,
    /// reads from the clock or waits for.
    struct Settings: Sendable {
        let duration: Duration
        let firstRID: Int
        let zx: @Sendable () -> String
        let now: @Sendable () -> Date
        /// The least time between one poll ending and the next opening,
        /// doubled for every empty poll in a row up to `longestWait`. Review
        /// finding 2: without it, a server answering polls with nothing was
        /// reopened as fast as the loop could run.
        let reopenGap: Duration
        /// How many polls in a row may carry nothing before the run stops.
        let maximumEmptyPolls: Int
        let sleep: @Sendable (Duration) async -> Void

        static let longestWait: Duration = .seconds(32)

        func wait(afterEmptyRun run: Int) -> Duration {
            min(reopenGap * (1 << min(max(0, run - 1), 10)), Self.longestWait)
        }
    }

    /// The watches added after the open go in batches of this many, the most
    /// the capture ever sent at once (review finding 5).
    static let batchSize = 10

    static func run(
        people: [Person],
        requests: PunctualRequests,
        client: PunctualClient,
        settings: Settings,
        log: PunctualProbeLog
    ) async {
        let watches = people.enumerated().map { index, person in
            PunctualWatch(sequence: index + 1, topic: .availability(userID: person.id))
        }
        guard let first = watches.first else {
            await log.append("Stopping: nobody to watch.")
            return
        }
        // The key is masked by name wherever it appears; the channel's own
        // identifiers join it once they exist (review finding 1).
        var labels = Dictionary(people.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        labels[requests.key] = "<key>"
        let context = Context(
            requests: requests,
            client: client,
            labels: labels,
            settings: settings,
            log: log
        )
        guard let channel = await context.open(
            first: first,
            rest: Array(watches.dropFirst()),
            firstRID: settings.firstRID
        )
        else {
            await log.append("Stopping: the channel never opened.")
            return
        }

        await log.append("")
        await log.append("pushes (times since the channel opened; keepalives counted, not printed):")
        let started = settings.now()
        let duration = settings.duration
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await context.poll(channel, startedAt: started) }
            group.addTask { try? await Task.sleep(for: duration) }
            await group.next()
            group.cancelAll()
        }
        await appendSummary(to: log)
    }

    private static func appendSummary(to log: PunctualProbeLog) async {
        await log.append("")
        await log.append("polls: \(log.polls), arrays: \(log.arrays), keepalives: \(log.keepalives)")
        let counts = await log.shapeCounts
        await log.append("shapes (people and times collapsed):")
        if counts.isEmpty {
            await log.append("  none")
        }
        for (shape, count) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            await log.append("  \(count)x \(shape)")
        }
    }

    /// `person 3` and `self` become `person`, and `@now-3m` becomes `@t`, so
    /// the same push about two people counts once. Applied to the printer's
    /// own output, which holds no value to leak.
    static func collapsed(_ shape: String) -> String {
        shape
            .replacingOccurrences(
                of: #"(?<![\w"-])(person \d+|self)(?![\w"-])"#, with: "person", options: .regularExpression
            )
            .replacingOccurrences(of: #"@now[+-]\d+[smhd]"#, with: "@t", options: .regularExpression)
    }

    /// Error text for a report a human pastes: the core's framing and
    /// transport errors are scrubbed already, and anything else is reduced to
    /// its type name.
    static func describe(_ error: any Error) -> String {
        if let error = error as? ChunkParserError {
            return error.description
        }
        if let error = error as? ChannelChunkError {
            return error.description
        }
        if let error = error as? ClassifiedTransportFailure {
            return error.reason.safeDescription
        }
        return String(describing: type(of: error))
    }
}

private extension PunctualWatchRun {
    enum PollOutcome {
        case ended(arrays: Int)
        case recoverable
        case stop
    }

    struct Context: Sendable {
        let requests: PunctualRequests
        let client: PunctualClient
        let labels: [String: String]
        let settings: Settings
        let log: PunctualProbeLog

        private var now: @Sendable () -> Date {
            settings.now
        }

        private func zx() -> String {
            settings.zx()
        }

        func open(first: PunctualWatch, rest: [PunctualWatch], firstRID: Int) async -> PunctualChannelID? {
            guard let gsessionID = await chooseServer(first.topic),
                  let sid = await openChannel(gsessionID: gsessionID, rid: firstRID, watch: first)
            else { return nil }
            let channel = PunctualChannelID(gsessionID: gsessionID, sid: sid)
            let batches = stride(from: 0, to: rest.count, by: PunctualWatchRun.batchSize).map {
                Array(rest[$0 ..< min($0 + PunctualWatchRun.batchSize, rest.count)])
            }
            for (index, batch) in batches.enumerated() {
                await add(batch, to: channel, rid: firstRID + 1 + index)
            }
            return channel
        }

        private func masks(_ channel: PunctualChannelID) -> [String: String] {
            labels.merging(
                [channel.gsessionID: "<gsessionid>", channel.sid: "<sid>"],
                uniquingKeysWith: { _, secret in secret }
            )
        }

        private func chooseServer(_ topic: PunctualTopic) async -> String? {
            guard let response = await send("choose server", { try requests.chooseServer(topic) }) else {
                return nil
            }
            guard let gsessionID = try? PunctualAnswers.gsessionID(inChooseServer: response.body) else {
                await log.append("choose server: no gsessionid in \(shape(of: response.body, masks: labels))")
                return nil
            }
            let masked = labels.merging(
                [gsessionID: "<gsessionid>"],
                uniquingKeysWith: { _, secret in secret }
            )
            let answer = shape(of: response.body, masks: masked)
            await log.append("choose server: gsessionid \(gsessionID.count) chars, answer \(answer)")
            return gsessionID
        }

        private func openChannel(gsessionID: String, rid: Int, watch: PunctualWatch) async -> String? {
            guard let response = await send("open", {
                try requests.open(gsessionID: gsessionID, rid: rid, zx: zx(), watch: watch)
            }) else { return nil }
            let body = String(decoding: response.body, as: UTF8.self)
            let partial = labels.merging(
                [gsessionID: "<gsessionid>"],
                uniquingKeysWith: { _, secret in secret }
            )
            guard let sid = try? PunctualAnswers.sid(inOpen: body) else {
                await log.append("open: no SID in \(shape(of: response.body, masks: partial))")
                return nil
            }
            let channel = PunctualChannelID(gsessionID: gsessionID, sid: sid)
            await log
                .append(
                    "open: SID \(sid.count) chars, answer \(shape(of: response.body, masks: masks(channel)))"
                )
            return sid
        }

        /// A refused add is reported and the run goes on: the first watch is
        /// already on the channel, and its pushes are still evidence.
        private func add(_ watches: [PunctualWatch], to channel: PunctualChannelID, rid: Int) async {
            guard let response = await send("add", {
                try requests.add(watches, on: channel, rid: rid, aid: 0, zx: zx())
            }) else { return }
            await log
                .append(
                    "add: \(watches.count) watches, answer \(shape(of: response.body, masks: masks(channel)))"
                )
        }

        /// Sends one handshake request. `nil` once a failure or a non-200 has
        /// been logged.
        private func send(_ stage: String, _ build: () throws -> HTTPRequest) async -> HTTPResponse? {
            let response: HTTPResponse
            do {
                response = try await client.send(build())
            } catch {
                await log.append("\(stage) failed: \(PunctualWatchRun.describe(error))")
                return nil
            }
            guard response.status == 200 else {
                await log.append("\(stage): status \(response.status), \(response.body.count) bytes")
                return nil
            }
            return response
        }

        /// Long-polls until the deadline cancels it, a poll fails for a reason
        /// that is not a timeout or a lost connection, or too many polls in a
        /// row carry nothing. Each reopen waits `Settings.wait(afterEmptyRun:)`
        /// and acknowledges the highest array seen.
        func poll(_ channel: PunctualChannelID, startedAt: Date) async {
            let masks = masks(channel)
            var aid = 0
            var number = 0
            var emptyRun = 0
            while true {
                number += 1
                await log.countPoll()
                switch await pollOnce(number, channel, aid: &aid, masks: masks, startedAt: startedAt) {
                case .stop:
                    return
                case let .ended(arrays):
                    emptyRun = arrays == 0 ? emptyRun + 1 : 0
                case .recoverable:
                    emptyRun += 1
                }
                if emptyRun >= settings.maximumEmptyPolls {
                    await log.append("Stopping: \(emptyRun) polls in a row carried nothing.")
                    return
                }
                await settings.sleep(settings.wait(afterEmptyRun: emptyRun))
                if Task.isCancelled {
                    await log.append("stopped at the deadline, between polls")
                    return
                }
            }
        }

        private func pollOnce(
            _ number: Int,
            _ channel: PunctualChannelID,
            aid: inout Int,
            masks: [String: String],
            startedAt: Date
        ) async -> PollOutcome {
            do {
                let stream = try await client.stream(requests.poll(on: channel, aid: aid, zx: zx()))
                guard stream.status == 200 else {
                    await log.append("poll \(number): status \(stream.status)")
                    return .stop
                }
                var parser = ChunkParser()
                var arrays = 0
                for try await bytes in stream.body {
                    for chunk in try parser.chunks(from: bytes) {
                        for array in try ChannelChunk.arrays(in: chunk) {
                            aid = max(aid, array.aid)
                            arrays += 1
                            await record(array, masks: masks, startedAt: startedAt)
                        }
                    }
                }
                // A cancelled stream can end quietly rather than throw, so the
                // deadline is checked here as well as below.
                if Task.isCancelled {
                    await log.append("poll \(number): stopped at the deadline")
                    return .stop
                }
                // How long a Punctual poll stays open is itself unknown.
                await log.append("poll \(number): ended at \(offset(since: startedAt)), \(arrays) arrays")
                return .ended(arrays: arrays)
            } catch {
                if Task.isCancelled {
                    await log.append("poll \(number): stopped at the deadline")
                    return .stop
                }
                // Review finding 3: a quiet channel outlasting the request
                // timeout is not the end of the run.
                if let failure = error as? ClassifiedTransportFailure,
                   failure.reason == .timedOut || failure.reason == .connectionLost {
                    await log.append("poll \(number): \(failure.reason.safeDescription), reopening")
                    return .recoverable
                }
                await log.append("poll \(number) failed: \(PunctualWatchRun.describe(error))")
                return .stop
            }
        }

        private func record(_ array: ChannelArray, masks: [String: String], startedAt: Date) async {
            await log.record(
                aid: array.aid,
                shape: PunctualPushShape.render(array.data, people: masks, now: now()),
                isKeepalive: array.isKeepalive,
                at: offset(since: startedAt)
            )
        }

        private func offset(since startedAt: Date) -> String {
            let elapsed = max(0, Int(now().timeIntervalSince(startedAt)))
            return String(format: "+%02d:%02d", elapsed / 60, elapsed % 60)
        }

        /// An answer's shape, through the same printer as the pushes. A body
        /// that is not JSON, framed or bare, is reported by its length.
        private func shape(of body: Data, masks: [String: String]) -> String {
            var text = Substring(String(decoding: body, as: UTF8.self))
            if let newline = text.firstIndex(of: "\n"), text[..<newline].allSatisfy(\.isNumber) {
                text = text[text.index(after: newline)...]
            }
            guard let value = try? PBLiteValue(json: Data(text.utf8)) else {
                return "(not JSON, \(body.count) bytes)"
            }
            return PunctualPushShape.render(value, people: masks, now: now())
        }
    }
}
