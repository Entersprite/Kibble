import AppCore
import ChatAPI
import ChatKit
import ChatService
import Foundation
import InProcessChatTransport
import ServiceClient

extension SystemAccountHost {
    func loadDefaults(service: ChatService) async {
        globalSidebar = AppEnvironment.globalSidebar(in: settingsPreferences)
        let model = DefaultPolicyModel(client: workspaceClient(service: service))
        defaultPolicy = model
        await model.load()
    }

    var settingsPreferences: UserDefaults {
        usesGoogleAccounts ? .standard :
            UserDefaults(suiteName: "com.entersprite.kibble.multi-account-fixture")!
    }

    func workspaceClient(service: ChatService) -> AccountClient {
        AccountClient(transport: InProcessChatTransport(endpoint: service, context: ServiceSessionContext(
            principalID: principalID, deviceID: deviceID, sessionID: ClientSessionID(UUID().uuidString),
            accounts: [], hasAllAccountAccess: true, canLinkAccounts: usesGoogleAccounts
        )))
    }

    public func updateGlobalSidebar(_ value: SidebarPreferences?) {
        guard !isDeletingUserData else { return }
        AppEnvironment.setGlobalSidebar(value, in: settingsPreferences)
        globalSidebar = AppEnvironment.globalSidebar(in: settingsPreferences)
        for account in workspace?.accounts ?? [] {
            workspace?.environment(for: account.id)?.refreshPersonalPreferences()
        }
    }
}
