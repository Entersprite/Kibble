import Foundation

/// Diagnostics that replace a Mac launch. Instrumentation flags such as
/// `--probe=markread` are deliberately absent: they run alongside the app.
enum MacLaunchProbe: Sendable, Equatable {
    case keychain
    case api
    case punctual
    case upload
    case people
    case edit
    case search
    case meetResolve
    case meetCall

    static func parsing(_ arguments: [String]) -> Self? {
        if arguments.contains("--probe=keychain") {
            return .keychain
        }
        if arguments.contains("--probe=api") {
            return .api
        }
        if arguments.contains("--probe=punctual") {
            return .punctual
        }
        if arguments.contains("--probe=upload") {
            return .upload
        }
        if arguments.contains("--probe=people") {
            return .people
        }
        if arguments.contains("--probe=search") {
            return .search
        }
        if arguments.contains("--probe=meet-resolve") {
            return .meetResolve
        }
        #if DEBUG
            if arguments.contains("--probe=meet-call") {
                return .meetCall
            }
        #endif
        if arguments.contains("--probe=edit") {
            return .edit
        }
        return nil
    }
}
