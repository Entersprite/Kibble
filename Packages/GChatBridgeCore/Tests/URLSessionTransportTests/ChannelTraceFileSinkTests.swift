import Foundation
import GChatBridgeCore
import Testing
@testable import URLSessionTransport

/// `ChannelTraceFileSink`'s pure formatting - `formattedFields(_:)` - gets a
/// direct test with synthetic input, no file and no socket. The rest of the
/// type is a thin file-writing boundary, the same shape this repo already
/// accepts for `SecItem` and `WKWebView` (see its own doc comment) - **except
/// for the one piece of real logic it grew**, the lock guarding its
/// open-seek-write sequence, which is exactly what
/// `ChannelTraceFileSinkConcurrencyTests` below exists to exercise: a lock
/// either serialises real concurrent writers correctly or it does not, and
/// that is only provable by actually racing them against a real file.
@Suite("Channel trace file sink - pure formatting")
struct ChannelTraceFileSinkTests {
    @Test("field number, wire type and byte count are joined with \":\", fields with \"|\"")
    func fieldsAreCompactlyJoined() {
        let shape = ProtoShape(
            fields: [
                ProtoField(number: 1, wireType: 0, byteCount: 1),
                ProtoField(number: 4, wireType: 2, byteCount: 37)
            ],
            truncated: false
        )
        #expect(ChannelTraceFileSink.formattedFields(shape) == "1:0:1|4:2:37")
    }

    @Test("no fields formats as an empty string, not a stray separator")
    func noFieldsFormatsEmpty() {
        #expect(ChannelTraceFileSink.formattedFields(ProtoShape(fields: [], truncated: false)) == "")
    }
}

/// Regression coverage for the corruption `ChannelTraceFileSink`'s own doc
/// comment describes (`findings.md` §26.1): a row missing its leading fields,
/// with every later value shifted under the wrong header, produced by two
/// `appendRow` calls racing an unsynchronised open-seek-write sequence rather
/// than by any single call site ever building a short row on purpose.
///
/// These tests drive the **real** sink against a **real** temporary file with
/// many genuinely concurrent writers and no external synchronisation at the
/// call site - the lock inside the sink is the only thing standing between
/// this and the corruption above. Before this fix existed, this suite's first
/// test failed reproducibly (a wrong field count on at least one line, most
/// runs) with the lock's `withLock` wrapper removed; every run since has
/// passed, which is the evidence the lock is what closed the gap rather than
/// the count of writers happening to be too small to race in practice.
@Suite("Channel trace file sink - concurrent writers")
struct ChannelTraceFileSinkConcurrencyTests {
    /// `header`'s own column count in `ChannelTraceFileSink` - kept as a
    /// literal here rather than derived, so a future column added to one but
    /// not the other shows up as a test failure instead of two files quietly
    /// agreeing with each other.
    private static let expectedFieldCount = 18

    /// A real sink over a real, scratch temporary file - `large_tuple` rules
    /// out returning `(sink, file, cleanup)` as a bare tuple, so this groups
    /// the same three facts as a type instead.
    private struct SinkFixture {
        let sink: ChannelTraceFileSink
        let file: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func makeSink() -> SinkFixture {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gchat-channel-trace-race-\(UUID().uuidString).csv")
        return SinkFixture(sink: ChannelTraceFileSink(writingTo: file), file: file)
    }

    /// One writer's contribution - deliberately varied lengths (a short
    /// `fireAndForget` failure against a `call` carrying a long
    /// `protoFields` column), since the corruption this reproduces depends on
    /// one racing row being shorter than the other.
    private func fire(_ sink: ChannelTraceFileSink, index: Int) {
        let startedAt = ContinuousClock.now
        switch index % 4 {
        case 0:
            sink.streamOpened(kind: "reopen", at: startedAt)
        case 1:
            sink.batchArrived(ChannelTraceBatch(
                byteCount: 512, gapSincePrevious: .milliseconds(30), start: startedAt,
                end: startedAt + .milliseconds(1)
            ))
        case 2:
            // Short: mirrors the real capture's `register` failure row.
            sink.unaryCallCompleted(UnaryCallRecord(
                label: "register",
                method: "GET",
                requestByteCount: 0,
                responseByteCount: nil,
                responseBodyShape: nil,
                outcome: .error("not connected to the internet"),
                duration: .milliseconds(4),
                startedAt: startedAt
            ))
        default:
            // Long: mirrors the real capture's `create_topic` success row.
            sink.unaryCallCompleted(UnaryCallRecord(
                label: "create_topic",
                method: "POST",
                requestByteCount: 96,
                responseByteCount: 286,
                responseBodyShape: ProtoShape(
                    fields: [
                        ProtoField(number: 1, wireType: 2, byteCount: 263),
                        ProtoField(number: 2, wireType: 2, byteCount: 18)
                    ],
                    truncated: false
                ),
                outcome: .completed(status: 200),
                duration: .milliseconds(407),
                startedAt: startedAt
            ))
        }
    }

    private func rows(in file: URL) throws -> [[String]] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return lines.dropFirst().map { $0.components(separatedBy: ",") } // drop the header
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
            let startSeconds = try #require(
                Double(fields[0]),
                "missing/unparsable start timestamp: \(fields)"
            )
            let endSeconds = try #require(Double(fields[1]), "missing/unparsable end timestamp: \(fields)")
            #expect(endSeconds >= startSeconds)
            #expect(!fields[2].isEmpty, "missing event name: \(fields)")
        }
    }

    /// The stronger check: not just "18 fields", but that a `call`/
    /// `fireAndForget` row's own fields land under the columns they belong
    /// under, the exact property the malformed row broke.
    @Test("a concurrent call row keeps its outcome, method and label in their own columns")
    func concurrentCallRowsStayCorrectlyAligned() async throws {
        let fixture = makeSink()
        defer { fixture.cleanup() }
        let writerCount = 200

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< writerCount {
                group.addTask { fire(fixture.sink, index: index) }
            }
        }

        let rows = try rows(in: fixture.file)
        let callRows = rows.filter { $0[2] == "call" || $0[2] == "fireAndForget" }
        // Half the writers (index % 4 == 2 or 3) produced a call-shaped row.
        #expect(callRows.count == writerCount / 2)
        for fields in callRows {
            let kind = fields[3] // "kind"
            #expect(
                kind == "register" || kind == "create_topic",
                "kind landed in the wrong column: \(fields)"
            )
            let outcome = fields[11] // "outcome"
            #expect(
                outcome == "completed" || outcome.hasPrefix("error:"),
                "outcome landed in the wrong column: \(fields)"
            )
            let httpMethod = fields[12] // "httpMethod"
            #expect(
                httpMethod == "GET" || httpMethod == "POST",
                "httpMethod landed in the wrong column: \(fields)"
            )
        }
    }
}
