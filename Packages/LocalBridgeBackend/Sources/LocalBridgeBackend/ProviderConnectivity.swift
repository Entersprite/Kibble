import Foundation
import GChatBridgeCore
import URLSessionTransport

public struct ProviderConnectivity: Sendable {
    let monitor: (any ReachabilityMonitor)?

    public static let timerOnly = ProviderConnectivity(monitor: nil)

    public static func native() -> ProviderConnectivity {
        #if canImport(Network)
            ProviderConnectivity(monitor: NWPathReachabilityMonitor())
        #else
            .timerOnly
        #endif
    }
}
