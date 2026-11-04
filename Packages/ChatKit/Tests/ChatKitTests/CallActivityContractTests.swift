import Foundation
import Testing
@testable import ChatKit

struct CallActivityContractTests {
    @Test func missingOptionalActivityStateIsUnknownAndFutureActionNamesRoundTrip() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let state = try decoder.decode(CallActivitiesState.self, from: Data("{}".utf8))
        #expect(state.availableActions.isEmpty && state.people.isEmpty && state.artifacts.isEmpty)
        #expect(state.attendanceReportEnabled == nil)
        let action = try decoder.decode(CallActivity.self, from: Data(#"{"action":"futureActivity"}"#.utf8))
        #expect(action.action == "futureActivity" && action.participantIDs.isEmpty && action.enabled)
        #expect(try decoder.decode(CallActivity.self, from: encoder.encode(action)) == action)
        #expect(throws: DecodingError.self) {
            try decoder.decode(CallActivitiesState.self, from: Data(#"{"availableActions":false}"#.utf8))
        }
    }
}
