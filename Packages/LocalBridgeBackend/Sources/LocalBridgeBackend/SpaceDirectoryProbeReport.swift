import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// A bounded, read-only directory check. Reports counts and protocol enums, never account values.
public enum SpaceDirectoryProbeReport {
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        query: String = "", flush: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> String {
        var lines = ["Space directory pipeline probe (reads only)", "query length: \(query.count)"]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let bootstrap = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: ChatEndpoints(),
                  lines: &lines
              ) else { return lines.joined(separator: "\n") }
        let client = ProtoAPIClient(
            transport: transport, endpoints: ChatEndpoints(), credentials: bootstrap.credentials,
            xsrfToken: bootstrap.wiz.xsrfToken
        )
        let known: [Conversation.ID: Conversation]
        do {
            let world = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            known = Dictionary(world.worldItems.compactMap { item in
                WorldMapping.conversation(from: item).map { ($0.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            lines.append("known conversation count: \(known.count)")
        } catch {
            lines.append("world read failed: \(APIProbeReport.safeDescription(of: error))")
            return lines.joined(separator: "\n")
        }
        let initial = lines.joined(separator: "\n")
        flush(initial)
        lines += await inspect(
            client: client,
            query: query,
            known: known,
            flush: { flush(initial + "\n" + $0) }
        )
        lines += await SpaceDirectoryControlProbe.run(client: client, query: query, known: known)
        return lines.joined(separator: "\n")
    }

    static func inspect(
        client: ProtoAPIClient, query: String, known: [Conversation.ID: Conversation] = [:],
        flush: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [String] {
        let report = DirectoryProbeProgress(flush: flush)
        let reader = SpaceDirectoryReader(client: client, known: known, progress: { await report.append($0) })
        do {
            await report.append("empty-query pipeline started")
            let first = try await reader.discover("", token: nil, key: "probe-empty")
            await report.append("empty-query pipeline returned rows: \(first.spaces.count)")
            // Search a returned name without printing it or needing another capture.
            let text = query.isEmpty ? first.spaces.first?.conversation.title ?? "" : query
            if !text.isEmpty {
                await report.append("typed-query pipeline started queryLength: \(text.count)")
                let searched = try await reader.discover(text, token: nil, key: "probe-typed")
                await report.append("typed-query pipeline returned rows: \(searched.spaces.count)")
                let prefix = String(text.prefix(3))
                await report.append("partial-query pipeline started")
                let partial = try await reader.discover(prefix, token: nil, key: "probe-partial")
                await report.append("partial-query pipeline returned rows: \(partial.spaces.count)")
            }
        } catch {
            await report.append("pipeline failed: \(APIProbeReport.safeDescription(of: error))")
        }
        return await report.lines
    }
}

private actor DirectoryProbeProgress {
    let started = ContinuousClock.now
    let flush: @Sendable (String) -> Void
    private(set) var lines: [String] = []

    init(flush: @escaping @Sendable (String) -> Void) {
        self.flush = flush
    }

    func append(_ stage: String) {
        let elapsed = started.duration(to: .now).components
        let millis = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        lines.append("\(millis)ms \(stage)")
        flush(lines.joined(separator: "\n"))
    }
}
