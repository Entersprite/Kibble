import AppKit

/// A JavaScript dialog the sign-in page asked for, which `LoginBrowser` shows
/// as a sheet on its window.
enum LoginPageDialog: Equatable {
    case alert(String)
    case confirm(String)
    case prompt(String, defaultText: String?)

    /// The person's answer, as WebKit wants it.
    struct Answer: Equatable {
        /// OK on a confirmation; false for Cancel, and for a refusal.
        var confirmed: Bool
        /// The text entered on a prompt's OK; nil for Cancel or a refusal.
        var text: String?
    }

    var message: String {
        switch self {
        case let .alert(message), let .confirm(message), let .prompt(message, _): message
        }
    }

    var canCancel: Bool {
        if case .alert = self {
            return false
        }
        return true
    }

    /// Names the page's origin, as browsers do, so a page cannot pass its
    /// words off as Kibble's.
    static func title(host: String?) -> String {
        guard let host, !host.isEmpty else { return "This page says" }
        return "\(host) says"
    }

    /// What a sheet's response means: only OK, the first button, confirms.
    /// Cancel, Esc and a refusal all answer no.
    func answer(_ response: NSApplication.ModalResponse, text: String?) -> Answer {
        let confirmed = response == .alertFirstButtonReturn
        switch self {
        case .alert: return Answer(confirmed: true)
        case .confirm: return Answer(confirmed: confirmed)
        case .prompt: return Answer(confirmed: confirmed, text: confirmed ? text ?? "" : nil)
        }
    }
}

/// One dialog's answer to WebKit, sent exactly once: the person's choice, or
/// a refusal when the dialog ends any other way. WebKit raises an exception
/// if a dialog's completion handler is released without being called, so
/// a reply that is let go unanswered refuses on its way out.
@MainActor
final class LoginDialogReply {
    private let dialog: LoginPageDialog
    private var send: (@MainActor (LoginPageDialog.Answer) -> Void)?

    init(dialog: LoginPageDialog, send: @escaping @MainActor (LoginPageDialog.Answer) -> Void) {
        self.dialog = dialog
        self.send = send
    }

    var isAnswered: Bool {
        send == nil
    }

    func answer(_ response: NSApplication.ModalResponse, text: String? = nil) {
        guard let send else { return }
        self.send = nil
        send(dialog.answer(response, text: text))
    }

    func refuse() {
        answer(.cancel)
    }

    isolated deinit {
        refuse()
    }
}
