import ChatKit
import Testing
@testable import SyncEngine

/// A sheet's error line says what went wrong in words, never Foundation's
/// "The operation couldn't be completed. (ChatKit.ChatError error 6.)".
@MainActor
struct ConversationBrowserErrorTextTests {
    @Test func anErrorCarryingAMessageShowsThatMessage() {
        let neutral = "The account operation could not be completed."
        #expect(ConversationBrowser.message(ChatError.unknown(neutral)) == neutral)
        #expect(ConversationBrowser.message(ChatError.decoding("Some membership records could not be read."))
            == "Some membership records could not be read.")
        #expect(ConversationBrowser.message(ChatError.server(status: 403, message: "Not allowed."))
            == "Not allowed.")
    }

    @Test func everyKindReadsAsASentence() {
        let errors: [ChatError] = [
            .notAuthenticated, .sessionExpired, .rateLimited(retryAfter: nil),
            .unsupported(capability: "addPeople"), .signInRequired("files"), .transport("offline"),
            .decoding(""), .server(status: 500, message: ""), .unknown("")
        ]
        for error in errors {
            let text = ConversationBrowser.message(error)
            #expect(!text.isEmpty)
            #expect(!text.contains("ChatError"))
        }
    }
}
