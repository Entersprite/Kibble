import ChatKit
import Foundation
import GChatBridgeCore

/// How many people a conversation has, from `segmented_membership_counts`
/// (field 30).
///
/// Its own file because `WorldMapping.swift` holds the fields every
/// conversation is built from, and this is one whose meaning is still an
/// inference: the field was seen on every world item (`findings.md` §20.4)
/// and named from purple's newer proto (§37.1), but its values have never
/// been decoded on the live account `[Verify]`, §43. The probe's
/// `membership counts` section is what settles it.
extension WorldMapping {
    /// The JOINED segments, summed, or `nil`.
    ///
    /// **Summed across member types**, because purple names two - a human
    /// user and a roster member (a Google Group added whole) - and Chat's own
    /// header counts both as people in the space. **JOINED only**, because an
    /// invitation is not membership. **A segment with no state is skipped**,
    /// not assumed joined: an absent state reads as `MEMBER_UNKNOWN`, and
    /// proto2 clears the presence bit for a state outside the vendored enum,
    /// so a value this build does not know takes the same path.
    ///
    /// **Zero is `nil`.** The account is itself a member of every conversation
    /// the world lists, so a total of zero means the rule above is wrong for
    /// this data, and "0 members" is the meaningless header this exists to
    /// remove.
    static func memberCount(for item: WorldItemLite) -> Int? {
        guard item.hasSegmentedMembershipCounts else { return nil }
        let joined = item.segmentedMembershipCounts.value
            .filter { $0.membershipState == .memberJoined }
            .reduce(0) { $0 + Int($1.membershipCount) }
        return joined > 0 ? joined : nil
    }
}
