import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import AppCore

@MainActor
struct DefaultPolicyModelTests {
    @Test func reopeningDuringAHeldWriteCannotRestoreOldDefaultsOrLoseANewerChoice() async {
        let transport = HeldDefaultPolicyTransport()
        let model = DefaultPolicyModel(client: AccountClient(transport: transport))
        await model.load()
        model.update(.init(sound: .system))
        #expect(await eventually { await transport.isHeld })
        await model.load()
        #expect(model.rule.sound == .system)
        model.update(.init(sound: .system, showsPreview: false))
        await transport.release()
        #expect(await eventually { await transport.savedRule.showsPreview == false })
        #expect(model.rule.sound == .system)
        #expect(model.rule.showsPreview == false)
        await model.stop()
    }
}

private actor HeldDefaultPolicyTransport: ServiceTransport {
    private var policy = AccountPolicy(revision: "0", settings: .init())
    private var held: CheckedContinuation<Void, Never>?
    private var blocks = true
    var isHeld: Bool {
        held != nil
    }

    var savedRule: NotificationRule {
        policy.settings.rule(for: .global) ?? .init()
    }

    func negotiate(_ peer: ServiceAPIVersion) -> ServiceAPIVersion {
        peer
    }

    func release() {
        blocks = false
        held?.resume()
        held = nil
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        if request.operation == SetDefaultPolicy.operation {
            let payload = try request.decodePayload(SetDefaultPolicy.self)
            if blocks {
                await withCheckedContinuation { held = $0 }
            }
            var settings = NotificationSettings()
            settings.setRule(payload.rule, for: .global, at: .distantPast, by: "device")
            policy = AccountPolicy(revision: "saved", settings: settings)
        }
        return try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(policy)))
    }
}
