public extension Capabilities {
    var canDiscoverCalls: Bool {
        extendedFlags.contains("callDiscovery")
    }

    var canReadCallHistory: Bool {
        extendedFlags.contains("callHistory")
    }
}
