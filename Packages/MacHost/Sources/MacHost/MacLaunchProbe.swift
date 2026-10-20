import Foundation

/// Diagnostics that replace a Mac launch. Instrumentation flags such as
/// `--probe=markread` are deliberately absent: they run alongside the app.
enum MacLaunchProbe: Sendable, Hashable {
    case keychain
    case api
    case punctual
    case upload
    case people
    case organization
    case edit
    case search
    case spaces
    case meetResolve
    case meetCall

    /// The first flag present wins, in this order.
    private static var flags: [(flag: String, probe: Self)] {
        var flags: [(flag: String, probe: Self)] = [
            ("--probe=keychain", .keychain), ("--probe=api", .api), ("--probe=punctual", .punctual),
            ("--probe=upload", .upload), ("--probe=people", .people),
            ("--probe=organization", .organization), ("--probe=search", .search),
            ("--probe=spaces", .spaces), ("--probe=meet-resolve", .meetResolve)
        ]
        #if DEBUG
            flags.append(("--probe=meet-call", .meetCall))
        #endif
        flags.append(("--probe=edit", .edit))
        return flags
    }

    static func parsing(_ arguments: [String]) -> Self? {
        flags.first { arguments.contains($0.flag) }?.probe
    }
}
