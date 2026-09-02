import AppCore
import Foundation

extension AppEnvironment {
    /// Not `private`: `AppEnvironmentProbes` writes its own report files
    /// beside the same database, and this is the one place that path is
    /// computed - module-internal rather than duplicated.
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GChat", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
