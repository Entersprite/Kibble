import AppKit
import Foundation
import LocalBridgeBackend
import MetricKit

/// Keeps a small, local record of system crash and hang diagnostics. MetricKit
/// delivers these after the event, often on the next launch. Only the fields
/// explicitly assembled below reach disk or the export; raw payload JSON,
/// exception reasons, addresses, paths, and app data never do.
public final class DiagnosticReportStore: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private let maxReports = 20
    private var reports: [SanitizedDiagnostic] = []
    private var conversationActions: [ConversationActionRecord] = []
    private var readStateFailures: [ReadStateFailureRecord] = []
    private var historyResponses: [HistoryResponseRecord] = []
    private var memorySamples: [MemorySample] = []

    public init(directory: URL?) {
        self.directory = directory
        super.init()
        if let directory {
            let file = directory.appendingPathComponent("diagnostics.json")
            if let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([SanitizedDiagnostic].self, from: data) {
                reports = Array(saved.suffix(maxReports))
            }
            let actionFile = directory.appendingPathComponent("conversation-actions.json")
            if let data = try? Data(contentsOf: actionFile),
               let saved = try? JSONDecoder().decode([ConversationActionRecord].self, from: data) {
                conversationActions = Array(saved.suffix(50))
            }
            let readFile = directory.appendingPathComponent("read-state-failures.json")
            if let data = try? Data(contentsOf: readFile),
               let saved = try? JSONDecoder().decode([ReadStateFailureRecord].self, from: data) {
                readStateFailures = Array(saved.suffix(50))
            }
            let historyFile = directory.appendingPathComponent("history-responses.json")
            if let data = try? Data(contentsOf: historyFile),
               let saved = try? JSONDecoder().decode([HistoryResponseRecord].self, from: data) {
                historyResponses = Array(saved.suffix(50))
            }
            let memoryFile = directory.appendingPathComponent("memory-samples.json")
            if let data = try? Data(contentsOf: memoryFile),
               let saved = try? JSONDecoder().decode([MemorySample].self, from: data) {
                memorySamples = Array(saved.suffix(240))
            }
        }
    }

    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let receivedAt = Date()
        let incoming = payloads.flatMap { payload -> [SanitizedDiagnostic] in
            let crashes = (payload.crashDiagnostics ?? []).map { diagnostic in
                SanitizedDiagnostic(
                    kind: "crash", receivedAt: receivedAt, version: version, build: build,
                    osVersion: osVersion,
                    exceptionType: diagnostic.exceptionType?.intValue,
                    exceptionCode: diagnostic.exceptionCode?.int64Value,
                    signal: diagnostic.signal?.intValue,
                    stacks: SanitizedStack.from(diagnostic.callStackTree.jsonRepresentation())
                )
            }
            let hangs = (payload.hangDiagnostics ?? []).map { diagnostic in
                SanitizedDiagnostic(
                    kind: "hang", receivedAt: receivedAt, version: version, build: build,
                    osVersion: osVersion,
                    exceptionType: nil, exceptionCode: nil, signal: nil,
                    stacks: SanitizedStack.from(diagnostic.callStackTree.jsonRepresentation())
                )
            }
            return crashes + hangs
        }
        guard !incoming.isEmpty else { return }
        lock.lock()
        reports = Array((reports + incoming).suffix(maxReports))
        if let directory, let data = try? JSONEncoder().encode(reports) {
            try? data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        }
        lock.unlock()
    }

    public func recordConversationAction(_ observation: ConversationActionObservation) {
        let record = ConversationActionRecord(recordedAt: Date(), request: observation)
        lock.lock()
        conversationActions = Array((conversationActions + [record]).suffix(50))
        if let directory, let data = try? JSONEncoder().encode(conversationActions) {
            try? data.write(
                to: directory.appendingPathComponent("conversation-actions.json"),
                options: .atomic
            )
        }
        lock.unlock()
    }

    public func recordReadStateFailure(_ failure: ReadStateRequestFailure) {
        let record = ReadStateFailureRecord(
            recordedAt: Date(), status: failure.status, conversationKind: failure.conversationKind,
            requestedAgeSeconds: failure.requestedAgeSeconds,
            requestMinusWorldHeadSeconds: failure.requestMinusWorldHeadSeconds
        )
        lock.lock()
        readStateFailures = Array((readStateFailures + [record]).suffix(50))
        if let directory, let data = try? JSONEncoder().encode(readStateFailures) {
            try? data.write(
                to: directory.appendingPathComponent("read-state-failures.json"), options: .atomic
            )
        }
        lock.unlock()
    }

    public func recordHistoryResponse(_ response: HistoryResponseObservation) {
        let record = HistoryResponseRecord(
            recordedAt: Date(), phase: response.phase, conversationKind: response.conversationKind,
            topics: response.topics, messages: response.messages, skipped: response.skipped,
            containsFirstTopic: response.containsFirstTopic,
            containsLastTopic: response.containsLastTopic,
            newestMainAgeSeconds: response.newestMainAgeSeconds,
            worldHeadAgeSeconds: response.worldHeadAgeSeconds
        )
        lock.lock()
        historyResponses = Array((historyResponses + [record]).suffix(50))
        if let directory, let data = try? JSONEncoder().encode(historyResponses) {
            try? data.write(
                to: directory.appendingPathComponent("history-responses.json"), options: .atomic
            )
        }
        lock.unlock()
    }

    public func sampleMemory() {
        guard let bytes = MemoryFootprint.currentBytes() else { return }
        lock.lock()
        memorySamples = Array((memorySamples + [MemorySample(recordedAt: Date(), footprintBytes: bytes)])
            .suffix(240))
        if let directory, let data = try? JSONEncoder().encode(memorySamples) {
            try? data.write(to: directory.appendingPathComponent("memory-samples.json"), options: .atomic)
        }
        lock.unlock()
    }

    func exportData() throws -> Data {
        lock.lock()
        let snapshot = reports
        let actions = conversationActions
        let failures = readStateFailures
        let history = historyResponses
        let memory = memorySamples
        lock.unlock()
        let export = DiagnosticExport(
            schemaVersion: 2, reports: snapshot, conversationActions: actions, readStateFailures: failures,
            historyResponses: history, memorySamples: memory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    /// Help › Export Diagnostics…. The panel says what the file holds and
    /// what it leaves out, since the menu item has no room to.
    @MainActor
    public func export() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.prompt = "Export"
        panel.message = Self.exportDescription
        panel.nameFieldStringValue = "kibble-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportData().write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t export diagnostics"
            alert.informativeText = "Choose another location and try again."
            alert.runModal()
        }
    }

    static let exportDescription = "Saves available crash and hang reports, recent read-state errors, "
        + "history response summaries, and memory samples. The export contains app version, error codes, "
        + "stack offsets, and request ages. It excludes messages, account details, file paths, and memory "
        + "addresses. Reopen Kibble after a crash before exporting."
}

private struct DiagnosticExport: Codable {
    let schemaVersion: Int
    let reports: [SanitizedDiagnostic]
    let conversationActions: [ConversationActionRecord]
    let readStateFailures: [ReadStateFailureRecord]
    let historyResponses: [HistoryResponseRecord]
    let memorySamples: [MemorySample]
}

private struct ReadStateFailureRecord: Codable {
    let recordedAt: Date
    let status: Int
    let conversationKind: String
    let requestedAgeSeconds: Int
    let requestMinusWorldHeadSeconds: Int?
}

private struct HistoryResponseRecord: Codable {
    let recordedAt: Date
    let phase: String
    let conversationKind: String
    let topics: Int
    let messages: Int
    let skipped: Int
    let containsFirstTopic: Bool?
    let containsLastTopic: Bool?
    let newestMainAgeSeconds: Int?
    let worldHeadAgeSeconds: Int?
}

private struct MemorySample: Codable {
    let recordedAt: Date
    let footprintBytes: UInt64
}

struct SanitizedDiagnostic: Codable {
    let kind: String
    let receivedAt: Date
    let version: String
    let build: String
    let osVersion: String
    let exceptionType: Int?
    let exceptionCode: Int64?
    let signal: Int?
    let stacks: [SanitizedStack]
}

struct SanitizedStack: Codable {
    let attributed: Bool
    let frames: [SanitizedFrame]

    static func from(_ data: Data) -> [Self] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = json["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        return stacks.prefix(8).map { stack in
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var frames: [SanitizedFrame] = []
            for root in roots.prefix(64) {
                appendFrames(root, to: &frames)
            }
            return Self(attributed: stack["threadAttributed"] as? Bool ?? false, frames: frames)
        }
    }

    private static func appendFrames(_ root: [String: Any], to frames: inout [SanitizedFrame]) {
        var pending = [root]
        while let node = pending.popLast(), frames.count < 64 {
            if let uuid = node["binaryUUID"] as? String,
               UUID(uuidString: uuid) != nil,
               let offset = node["offsetIntoBinaryTextSegment"] as? NSNumber {
                frames.append(SanitizedFrame(binaryUUID: uuid, offset: offset.uint64Value))
            }
            if let children = node["subFrames"] as? [[String: Any]] {
                pending.append(contentsOf: children.prefix(64).reversed())
            }
        }
    }
}

struct SanitizedFrame: Codable {
    let binaryUUID: String
    let offset: UInt64
}

private struct ConversationActionRecord: Codable {
    let recordedAt: Date
    let request: ConversationActionObservation
}
