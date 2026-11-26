import Foundation

/// Tests that display native windows run only in the explicit desktop UI pass.
/// Kept in the test target so application behavior never depends on test mode.
var visibleUITestsEnabled: Bool {
    ProcessInfo.processInfo.environment["KIBBLE_VISIBLE_UI_TESTS"] == "1"
}
