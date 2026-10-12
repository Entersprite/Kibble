/// Names the endpoint whose connection state a backend reports. Supplied by
/// the host that chose the backend, so shared UI does not assume a provider.
public struct ConnectionService: Sendable, Equatable {
    /// Product name shown for a server problem, such as "Google Chat".
    public var name: String
    /// Operator named in network errors, such as "Google".
    public var operatorName: String

    public init(name: String, operatorName: String) {
        self.name = name
        self.operatorName = operatorName
    }
}
