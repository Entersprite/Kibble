import AppKit
import Foundation

/// Copies an explicitly requested report without retaining a call service.
@MainActor
final class AudioCallDiagnosticExporter {
    typealias Provider = @MainActor (UUID) async -> String?

    private var provider: Provider?
    private var session = UUID()
    private var request = UUID()
    private let write: (String) -> Bool

    var isAvailable: Bool {
        provider != nil
    }

    init(write: @escaping (String) -> Bool = { report in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(report, forType: .string)
    }) {
        self.write = write
    }

    func install(_ provider: Provider?) {
        session = UUID()
        request = UUID()
        self.provider = provider
    }

    func copy(
        callID: UUID, context: String? = nil, isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent(), let provider else { return false }
        let scope = session
        let ticket = UUID()
        request = ticket
        let native = await provider(callID)
        let report = [context, native].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !report.isEmpty, !Task.isCancelled, session == scope, request == ticket, isCurrent()
        else { return false }
        #if DEBUG
            let configuration = "Debug"
        #else
            let configuration = "Release"
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return write("Kibble call diagnostics\nVersion: \(version)\nConfiguration: \(configuration)\n" +
            report)
    }
}
