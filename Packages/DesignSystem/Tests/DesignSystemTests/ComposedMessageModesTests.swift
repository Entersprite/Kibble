import ChatKit
import Testing
@testable import DesignSystem

/// The confirmation's answer applied to a composed message (mention
/// non-members spec §2).
struct ComposedMessageModesTests {
    private let jane = Member.ID("jane")
    private let bo = Member.ID("bo")

    private var message: ComposedMessage {
        ComposedMessage(text: "@Jane Doe hi @Bo @all", mentions: [
            Mention(target: .user(jane), start: 0, length: 9),
            Mention(target: .user(bo), start: 13, length: 3),
            Mention(target: .all, start: 17, length: 4)
        ])
    }

    @Test func onlyTheNamedPeopleChangeMode() {
        let changed = message.settingMode(.invite, for: [jane])
        #expect(changed.mentions.map(\.mode) == [.invite, .mention, .mention])
        #expect(changed.text == message.text)
    }

    @Test func namesComeFromTheTokens() {
        #expect(message.names(of: [bo, jane]) == ["Jane Doe", "Bo"])
    }

    @Test func aPersonNamedTwiceIsListedOnce() {
        let twice = ComposedMessage(text: "@Bo @Bo", mentions: [
            Mention(target: .user(bo), start: 0, length: 3),
            Mention(target: .user(bo), start: 4, length: 3)
        ])
        #expect(twice.names(of: [bo]) == ["Bo"])
    }
}
