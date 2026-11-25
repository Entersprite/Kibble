import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

extension NativeMeetHostControlsTests {
    @Test(arguments: [true, false])
    func inheritedAllowDoesNotConfirmAnExplicitChatPolicyWrite(defaultActive: Bool) async throws {
        let locked = snapshot(version: 1, management: true, chat: 3, savedChat: 3, legacyChatLocked: true)
        let readback = snapshot(
            version: 2, management: true, chat: defaultActive ? 1 : 2, savedChat: defaultActive ? 2 : 1
        )
        let (session, transport) = try await connect([locked, NativeMeetFixture.ok(Data()), readback])
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("allowChatMessages"))
        }
        #expect(await session.activities.hostSettings?.chatMessagesAllowed == true)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }
}
