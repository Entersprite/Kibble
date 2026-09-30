import Foundation
import Testing
@testable import GChatBridgeCore

/// The Punctual requests, asserted as exact strings against the shapes
/// `findings.md` §46.6 and §47 read out of Chat on the web's own traffic.
///
/// Exact for the reason `ChannelRequestsTests` is: the capture is the
/// specification, and a request that differs from it only slightly is the one
/// nobody can diagnose.
struct PunctualRequestsTests {
    private let requests = PunctualRequests(endpoints: ChatEndpoints(), key: "KEY")

    private func query(_ request: HTTPRequest) -> String {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    private func path(_ request: HTTPRequest) -> String {
        request.url.path
    }

    private func form(_ request: HTTPRequest) -> [(String, String)] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.body ?? Data(), as: UTF8.self)
        return (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    // MARK: - Topics and watches

    /// §46.6: one watch per person, `user-state-changes`, with `[1]` as the
    /// second element. Every character here is from the capture.
    @Test func anAvailabilityWatchIsTheCapturedShape() throws {
        let watch = PunctualWatch(sequence: 2, topic: .availability(userID: "123"))
        #expect(
            try watch.json()
                == #"[[[2,[null,null,null,[9,5],null,[["user-state-changes"],[1],"#
                + #"[[["state"],["user"],["123"],["availability"]]]],null,null,1],null,1]]]"#
        )
    }

    /// `chooseServer` takes the topic without the watch's sequence wrapper.
    @Test func chooseServerCarriesTheTopicInTheCapturedEnvelope() throws {
        let request = try requests.chooseServer(.availability(userID: "123"))
        #expect(
            String(decoding: request.body ?? Data(), as: UTF8.self)
                == #"[[null,null,null,[9,5],null,[["user-state-changes"],[1],"#
                + #"[[["state"],["user"],["123"],["availability"]]]]],null,null,0,0]"#
        )
    }

    // MARK: - chooseServer

    @Test func chooseServerPostsToTheServerPathWithTheKey() throws {
        let request = try requests.chooseServer(.availability(userID: "1"))
        #expect(request.method == .post)
        #expect(request.url.host == "chat.google.com")
        #expect(path(request) == "/punctual/prod-09-us/v1/chooseServer")
        #expect(query(request) == "key=KEY")
        #expect(request.headers["Content-Type"] == "application/json+protobuf")
    }

    /// Every Punctual request the web client made carried `x-goog-authuser`.
    /// Account 1 must say 1: a wrong index fails like bad credentials
    /// (`ChatEndpoints`' own doc comment).
    @Test func everyRequestNamesTheAccountIndex() throws {
        let second = PunctualRequests(endpoints: ChatEndpoints(account: .index(1)), key: "K")
        #expect(try second.chooseServer(.availability(userID: "1")).headers["X-Goog-AuthUser"] == "1")
        #expect(second.poll(on: PunctualChannelID(gsessionID: "g", sid: "s"), aid: 0, zx: "z")
            .headers["X-Goog-AuthUser"] == "1")
        #expect(try requests.chooseServer(.availability(userID: "1")).headers["X-Goog-AuthUser"] == "0")
    }

    /// Punctual lives on the host root, not under `/u/N`: the capture's paths
    /// have no account segment even though its API calls do.
    @Test func thePathHasNoAccountSegment() throws {
        let second = PunctualRequests(endpoints: ChatEndpoints(account: .index(1)), key: "K")
        #expect(try path(second.chooseServer(.availability(userID: "1"))) ==
            "/punctual/prod-09-us/v1/chooseServer")
    }

    @Test func theServerPathIsConfigurable() throws {
        let other = PunctualRequests(endpoints: ChatEndpoints(), serverPath: "prod-01-eu", key: "K")
        #expect(try path(other.chooseServer(.availability(userID: "1"))) ==
            "/punctual/prod-01-eu/v1/chooseServer")
    }

    // MARK: - The channel

    @Test func openingTheChannelSendsTheFirstWatch() throws {
        let watch = PunctualWatch(sequence: 1, topic: .availability(userID: "9"))
        let request = try requests.open(gsessionID: "GS", rid: 9753, zx: "zx1", watch: watch)
        #expect(request.method == .post)
        #expect(path(request) == "/punctual/prod-09-us/multi-watch/channel")
        #expect(query(request) == "VER=8&gsessionid=GS&key=KEY&RID=9753&CVER=22&zx=zx1&t=1")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["X-WebChannel-Content-Type"] == "application/json+protobuf")
        let fields = form(request)
        #expect(fields.map(\.0) == ["count", "ofs", "req0___data__"])
        #expect(fields[0].1 == "1")
        #expect(fields[1].1 == "0")
        #expect(try fields[2].1 == (watch.json()))
    }

    /// §46.6's second request: ten watches in one POST, `count=10`, and `ofs`
    /// the offset of the first of them, one less than its sequence.
    @Test func addingWatchesNumbersEachFieldAndCarriesTheOffset() throws {
        let watches = (3 ... 5).map { PunctualWatch(sequence: $0, topic: .availability(userID: "\($0)")) }
        let request = try requests.add(
            watches,
            on: PunctualChannelID(gsessionID: "GS", sid: "SID"),
            rid: 9755,
            aid: 3,
            zx: "zx2"
        )
        #expect(query(request) == "VER=8&gsessionid=GS&key=KEY&SID=SID&RID=9755&AID=3&zx=zx2&t=1")
        let fields = form(request)
        #expect(fields.map(\.0) == ["count", "ofs", "req0___data__", "req1___data__", "req2___data__"])
        #expect(fields[0].1 == "3")
        #expect(fields[1].1 == "2")
        // The capture's adds carried no `X-WebChannel-Content-Type`; only the open did.
        #expect(request.headers["X-WebChannel-Content-Type"] == nil)
        #expect(try fields[4].1 == (watches[2].json()))
    }

    /// The back channel. The capture has only its CORS preflight, whose query
    /// is the GET's own.
    @Test func thePollIsTheCapturedGet() {
        let request = requests.poll(on: PunctualChannelID(gsessionID: "GS", sid: "SID"), aid: 15, zx: "zx3")
        #expect(request.method == .get)
        #expect(path(request) == "/punctual/prod-09-us/multi-watch/channel")
        #expect(
            query(request)
                == "VER=8&gsessionid=GS&key=KEY&RID=rpc&SID=SID&AID=15&CI=0&TYPE=xmlhttp&zx=zx3&t=1"
        )
        #expect(request.body == nil)
    }

    @Test func everyRequestCarriesTheBrowserHeaders() throws {
        let channel = PunctualChannelID(gsessionID: "g", sid: "s")
        let watch = PunctualWatch(sequence: 2, topic: .availability(userID: "1"))
        for request in try [
            requests.chooseServer(.availability(userID: "1")),
            requests.open(gsessionID: "g", rid: 1, zx: "z", watch: watch),
            requests.add([watch], on: channel, rid: 2, aid: 0, zx: "z"),
            requests.poll(on: channel, aid: 0, zx: "z")
        ] {
            #expect(request.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
            #expect(request.headers["Origin"] == "https://chat.google.com")
            #expect(request.headers["referer"] == "https://chat.google.com/")
        }
    }

    // MARK: - Answers

    /// §47: `["<gsessionid>", 1, null, "<d16>", "<d16>"]`.
    @Test func theGsessionIDIsTheChooseServerAnswersFirstElement() throws {
        let body = Data(#"["gs-token",1,null,"1234567890123456","6543210987654321"]"#.utf8)
        #expect(try PunctualAnswers.gsessionID(inChooseServer: body) == "gs-token")
    }

    @Test func aChooseServerAnswerWithoutAStringFirstElementThrows() {
        #expect(throws: PunctualAnswerError.noSessionIdentifier) {
            try PunctualAnswers.gsessionID(inChooseServer: Data("[1,2]".utf8))
        }
    }

    /// §47: `[[0,["c","<SID>","",8,15,30000]]]`, with or without the
    /// BrowserChannel length prefix, which the capture cannot tell apart.
    @Test func theSIDComesFromTheOpenAnswerFramedOrNot() throws {
        let bare = #"[[0,["c","SID22","",8,15,30000]]]"#
        #expect(try PunctualAnswers.sid(inOpen: bare) == "SID22")
        #expect(try PunctualAnswers.sid(inOpen: "\(bare.utf8.count)\n\(bare)") == "SID22")
    }

    @Test func anOpenAnswerThatIsNotACreateThrows() {
        #expect(throws: PunctualAnswerError.noSessionIdentifier) {
            try PunctualAnswers.sid(inOpen: #"[[0,["noop"]]]"#)
        }
    }
}
