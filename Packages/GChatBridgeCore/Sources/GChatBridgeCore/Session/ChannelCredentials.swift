import Foundation

extension SessionCredentials {
    /// COMPASS is a browser routing hint, not account authentication. A saved
    /// hint can route a newly registered channel to a retired browser session;
    /// multiple scoped hints can also be sent together. The web client removes
    /// this cookie before opening its event channel. Keep the credential jar
    /// intact for other requests, while excluding every hint on this channel.
    func authorisingChannel(_ request: HTTPRequest) -> HTTPRequest {
        authorising(request, withholding: ["COMPASS"])
    }
}
