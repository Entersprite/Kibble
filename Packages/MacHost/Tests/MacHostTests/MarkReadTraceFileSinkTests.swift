import Foundation
import SyncEngine
import Testing
@testable import MacHost

/// Regression coverage for the same corruption `ChannelTraceFileSinkTests`
/// already documents (`findings.md` §26.1): a row missing its leading fields,
/// with every later value shifted under the wrong header, produced by two
/// `appendRow` calls racing an unsynchronised open-seek-write sequence rather
/// than any single call site ever building a short row on purpose.
/// `MarkReadTraceFileSink.appendRow` is the same three-step sequence guarded
/// by the same kind of lock, so this suite drives the real sink against a
/// real temporary file with many genuinely concurrent writers and no
/// external synchronisation at the call site.
@Suite("Mark-read trace file sink - concurrent writers")
struct MarkReadTraceFileSinkConcurrencyTests {
    /// `MarkReadTraceFileSink.header`'s own column count, kept as a literal
    /// here rather than derived, so a column added to one but not the other
    /// shows up as a test failure instead of two files quietly agreeing with
    /// each other - same reasoning as `ChannelTraceFileSinkConcurrencyTests`.
    private static let expectedFieldCount = 10

    private struct SinkFixture {
        let sink: MarkReadTraceFileSink
        let file: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func makeSink() -> SinkFixture {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gchat-markread-trace-race-\(UUID().uuidString).csv")
        return SinkFixture(sink: MarkReadTraceFileSink(writingTo: file), file: file)
    }

    /// One writer's contribution - varied row shapes (a decline, an accepted
    /// outcome, a read-state drop), since the corruption this reproduces
    /// depends on one racing row being shorter than another.
    private func fire(_ sink: MarkReadTraceFileSink, index: Int) {
        let at = ContinuousClock.now
        switch index % 3 {
        case 0:
            sink.triggerEvaluated(MarkReadTriggerRecord(
                conversation: index, outcome: .alreadyInFlight, loadedMessageCount: 3,
                filteredMessageCount: 3, newestAgeSeconds: 12.5, unreadCount: 2, at: at
            ))
        case 1:
            sink.markOutcome(MarkReadOutcomeRecord(
                conversation: index, accepted: true, duration: .milliseconds(240), at: at
            ))
        default:
            sink.readStateChanged(MarkReadStateRecord(conversation: index, unreadCount: 0, at: at))
        }
    }

    private func rows(in file: URL) throws -> [[String]] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Drop the header and the `config` row `init` writes immediately
        // after it (this instrument's own self-identification row - see
        // `MarkReadTraceFileSink.init`'s doc comment).
        return lines.dropFirst(2).map { $0.components(separatedBy: ",") }
    }

    @Test("many concurrent writers never tear a row - every line keeps its full, aligned field count")
    func concurrentWritersNeverTearARow() async throws {
        let fixture = makeSink()
        defer { fixture.cleanup() }
        let writerCount = 200

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< writerCount {
                group.addTask { fire(fixture.sink, index: index) }
            }
        }

        let rows = try rows(in: fixture.file)
        // No row lost and none merged into another: exactly one line per writer.
        #expect(rows.count == writerCount)
        for fields in rows {
            #expect(fields.count == Self.expectedFieldCount, "wrong column count: \(fields)")
            let elapsedSeconds = try #require(
                Double(fields[0]),
                "missing/unparsable elapsed time: \(fields)"
            )
            #expect(elapsedSeconds >= 0)
            #expect(!fields[1].isEmpty, "missing row kind: \(fields)")
        }
    }

    /// The stronger check: not just "10 fields", but that a row's own values
    /// land under the columns they belong under - the exact property the
    /// malformed row in §26.1 broke.
    @Test("a concurrent row keeps its conversation token and outcome in their own columns")
    func concurrentRowsStayCorrectlyAligned() async throws {
        let fixture = makeSink()
        defer { fixture.cleanup() }
        let writerCount = 201 // a multiple of 3, so every row kind appears equally often

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< writerCount {
                group.addTask { fire(fixture.sink, index: index) }
            }
        }

        let rows = try rows(in: fixture.file)
        let triggerRows = rows.filter { $0[1] == "trigger" }
        let outcomeRows = rows.filter { $0[1] == "outcome" }
        let readStateRows = rows.filter { $0[1] == "readState" }
        #expect(triggerRows.count == writerCount / 3)
        #expect(outcomeRows.count == writerCount / 3)
        #expect(readStateRows.count == writerCount / 3)

        for fields in triggerRows {
            #expect(fields[3] == "already-in-flight", "outcome landed in the wrong column: \(fields)")
            #expect(fields[7] == "2", "unreadCount landed in the wrong column: \(fields)")
        }
        for fields in outcomeRows {
            #expect(fields[8] == "true", "accepted landed in the wrong column: \(fields)")
        }
        for fields in readStateRows {
            #expect(fields[7] == "0", "unreadCount landed in the wrong column: \(fields)")
        }
    }
}

/// `MarkReadTriggerRecord.conversation` is an `Int?` (never the raw id) and
/// every numeric/optional field is written plainly - these tests exercise
/// the row-shaping directly, with no file and no concurrency, the
/// counterpart to `ChannelTraceFileSinkTests`' pure-formatting coverage.
@Suite("Mark-read trace file sink - row formatting")
struct MarkReadTraceFileSinkFormattingTests {
    private func writeOne(_ write: (MarkReadTraceFileSink) -> Void) throws -> [String] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gchat-markread-trace-format-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let sink = MarkReadTraceFileSink(writingTo: file)
        write(sink)
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // row 0 is the header, row 1 is `init`'s own `config` row.
        return lines[2].components(separatedBy: ",")
    }

    /// The self-identification row: `init` writes this immediately after the
    /// header, before any caller has evaluated a trigger, so any capture
    /// states which build's offset produced it and can never be silently
    /// mistaken for another build's (`findings.md` §12.2's own failure mode -
    /// this session's own two-day-old `channel-trace.csv` misread).
    @Test("init writes a self-identifying config row naming the read-position offset, before any other row")
    func initWritesTheConfigRow() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gchat-markread-trace-config-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = MarkReadTraceFileSink(writingTo: file, readPositionOffsetMicroseconds: 1)

        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2) // header, then the config row - nothing else yet
        let fields = lines[1].components(separatedBy: ",")
        #expect(fields.count == 10) // the same 10-column shape every other row keeps
        #expect(fields[1] == "config")
        #expect(fields[3] == "readPositionOffsetMicroseconds")
        #expect(fields[4] == "1")
    }

    @Test("nothingSelected's nil conversation and nil unreadCount write as empty columns, not \"nil\"")
    func nilFieldsWriteAsEmptyColumns() throws {
        let fields = try writeOne { sink in
            sink.triggerEvaluated(MarkReadTriggerRecord(
                conversation: nil, outcome: .nothingSelected, loadedMessageCount: 0,
                filteredMessageCount: 0, newestAgeSeconds: nil, unreadCount: nil, at: .now
            ))
        }
        #expect(fields[2].isEmpty) // conversation
        #expect(fields[6].isEmpty) // newestAgeSeconds
        #expect(fields[7].isEmpty) // unreadCount
    }

    @Test("a declined outcome names its guard token verbatim")
    func declineTokenIsWrittenVerbatim() throws {
        let fields = try writeOne { sink in
            sink.triggerEvaluated(MarkReadTriggerRecord(
                conversation: 3, outcome: .watermarkNotAdvanced, loadedMessageCount: 4,
                filteredMessageCount: 2, newestAgeSeconds: 0.25, unreadCount: 1, at: .now
            ))
        }
        #expect(fields[2] == "3")
        #expect(fields[3] == "watermark-not-advanced")
        #expect(fields[4] == "4")
        #expect(fields[5] == "2")
    }

    @Test("an outcome row's duration is milliseconds, fixed-point, never a locale decimal comma")
    func outcomeDurationIsMillisecondsFixedPoint() throws {
        let fields = try writeOne { sink in
            sink.markOutcome(MarkReadOutcomeRecord(
                conversation: 7,
                accepted: false,
                duration: .milliseconds(1234.5),
                at: .now
            ))
        }
        #expect(fields[2] == "7")
        #expect(fields[8] == "false")
        #expect(fields[9] == "1234.500")
    }
}
