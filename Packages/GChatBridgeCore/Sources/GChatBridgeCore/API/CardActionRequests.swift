import Foundation

public extension APIMethod where Request == SubmitFormActionRequest, Response == SubmitFormActionResponse {
    /// The callback route described by the upstream protocol schema.
    /// Native form input and dialog payloads are not yet supported.
    static var submitFormAction: Self {
        Self("submit_form_action")
    }
}
