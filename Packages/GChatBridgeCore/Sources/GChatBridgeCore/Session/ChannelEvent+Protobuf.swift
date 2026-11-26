import Foundation

public extension ChannelEvent {
    init(protobuf event: Event) throws {
        var bodies: [ChannelEventBody] = []
        if event.hasBody {
            try bodies.append(ChannelEventBody(
                typeTag: event.body.hasEventType ? event.body.eventType.rawValue : event.type.rawValue,
                value: PBLiteEncoder.encode(event.body)
            ))
        }
        for body in event.bodies {
            try bodies.append(ChannelEventBody(
                typeTag: body.hasEventType ? body.eventType.rawValue : nil, value: PBLiteEncoder.encode(body)
            ))
        }
        let revision: ChannelEventRevision? = switch event.revisionType {
        case let .groupRevision(value):
            .init(scope: .group, timestamp: value.timestamp, previousTimestamp: value.prevTimestamp)
        case let .userRevision(value):
            .init(scope: .user, timestamp: value.timestamp, previousTimestamp: value.prevTimestamp)
        case nil: nil
        }
        self.init(bodies: bodies, revision: revision)
    }
}
