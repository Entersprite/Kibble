import Foundation

/// One body inside a channel event, with the tag that says what it is.
///
/// The tag is kept as an `Int` as well as a named type, and that is the whole
/// design. `findings.md` §12.1.1: the vendored proto's `EventType` stops at 50
/// and live traffic carried **51, 64, 70 and 83** — four values no generated
/// Swift can name. Regenerating from a newer proto would shrink that set and
/// never empty it, because the set is Google's to grow.
public struct ChannelEventBody: Sendable, Hashable {
    /// The raw value of field 12, or `nil` when the body carried no readable
    /// tag.
    ///
    /// An untagged body is still a body. §12.1.1's rule is to route what is not
    /// understood, never to discard it — a dropped frame is a message that
    /// silently never arrives.
    public let typeTag: Int?

    /// The body itself, retained whether or not the tag is understood, so that
    /// a later mapping can be written against a capture rather than a guess.
    public let value: PBLiteValue

    public init(typeTag: Int?, value: PBLiteValue) {
        self.typeTag = typeTag
        self.value = value
    }

    /// The named type, when the vendored proto knows it.
    ///
    /// `nil` covers two different things on purpose — an absent tag and a tag
    /// from the future — because a caller does the same thing with both: route
    /// it as unknown and keep it. `typeTag` separates them for a log line.
    public var type: Event.EventType? {
        typeTag.flatMap(Event.EventType.init(rawValue:))
    }
}

/// The event carried by one delivered array.
///
/// ## Where it lives, and why that is worth a test
///
/// The event is at `payload[0][0]`, and its bodies at index 7. `payload[0]` is
/// a *wrapper* holding the event plus a 36-character id — reading that as the
/// event finds no bodies, silently, because a wrapper is a perfectly good
/// array. That mistake made a run carrying four `MESSAGE_POSTED` events report
/// `NOT PROVEN` on the project's gating criterion (§12.2), so the depth has a
/// test naming it rather than a comment hoping for it.
///
/// ## Two encodings for one tag
///
/// A body arrives either as a padded positional array with field 12 at index
/// 11, or — when its set fields are all high-numbered — as a trailing
/// dictionary keyed `"12"`. **Eight of the 33 bodies** in the first successful
/// run were the dictionary form, so a parser reading only the positional shape
/// would have called a quarter of the traffic untagged.
public struct ChannelEvent: Sendable, Hashable {
    public let bodies: [ChannelEventBody]

    public init(bodies: [ChannelEventBody]) {
        self.bodies = bodies
    }

    /// Reads the event out of a delivered array, or `nil` when it carries none
    /// — a keepalive, or any shape that is not an event.
    public init?(_ array: ChannelArray) {
        self.init(payload: array.data)
    }

    init?(payload: PBLiteValue) {
        guard
            let outer = payload.arrayValue,
            let wrapper = outer.first?.arrayValue,
            let event = wrapper.first?.arrayValue
        else { return nil }

        // Index 7. An event with fewer entries is one whose later fields were
        // all unset, which is ordinary rather than malformed.
        let bodies = event.count > 7 ? event[7].arrayValue ?? [] : []
        self.bodies = bodies.map {
            ChannelEventBody(typeTag: Self.typeTag(of: $0), value: $0)
        }
    }

    /// Field 12, in whichever of the two encodings the body used.
    private static func typeTag(of body: PBLiteValue) -> Int? {
        if let entries = body.objectValue {
            return entries["12"]?.intValue
        }
        guard let fields = body.arrayValue else { return nil }
        if fields.count > 11, let tag = fields[11].intValue {
            return tag
        }
        // A positional body can still carry a trailing dictionary for its
        // high-numbered fields, and that is where the tag then lives.
        for field in fields {
            if let tag = field.objectValue?["12"]?.intValue {
                return tag
            }
        }
        return nil
    }
}
