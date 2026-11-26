import Foundation

public struct ChannelEventRevision: Hashable, Sendable {
    public enum Scope: Hashable, Sendable { case user, group }
    public let scope: Scope
    public let timestamp: Int64
    public let previousTimestamp: Int64?

    public init(scope: Scope, timestamp: Int64, previousTimestamp: Int64? = nil) {
        self.scope = scope
        self.timestamp = timestamp
        self.previousTimestamp = previousTimestamp
    }
}

extension ChannelEvent {
    static func field(_ number: Int, in value: PBLiteValue) -> PBLiteValue? {
        if let object = value.objectValue {
            return object[String(number)]
        }
        guard let array = value.arrayValue else { return nil }
        if let extra = array.last?.objectValue?[String(number)] {
            return extra
        }
        guard number > 0, array.count >= number, array[number - 1] != .null else { return nil }
        return array[number - 1]
    }

    static func revision(in value: PBLiteValue) -> ChannelEventRevision? {
        for (number, scope) in [(7, ChannelEventRevision.Scope.group), (6, .user)] {
            guard let raw = field(number, in: value), let timestamp = integer(field(1, in: raw)),
                  timestamp > 0 else {
                continue
            }
            return ChannelEventRevision(
                scope: scope, timestamp: timestamp, previousTimestamp: integer(field(2, in: raw))
            )
        }
        return nil
    }

    private static func integer(_ value: PBLiteValue?) -> Int64? {
        value?.stringValue.flatMap(Int64.init) ?? value?.intValue.flatMap(Int64.init(exactly:))
    }
}
