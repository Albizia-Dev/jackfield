import XCTest
@testable import JackfieldCore

final class DiagnosticErrorStateTests: XCTestCase {
  func testLaterMethodErrorOverridesUnacknowledgedCapacityDrop() {
    var state = DiagnosticErrorState()
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "storageFull")
    state.record("platformFailure")
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "platformFailure")
  }

  func testFlutterAckClearsStaleStorageErrorButKeepsLaterError() {
    var state = DiagnosticErrorState()
    state.record("storageFull")
    state.acknowledgeFlutter()
    XCTAssertNil(state.visibleError(activeCapacityDrops: 0))

    state.record("storageFull")
    state.record("deadlineExceeded")
    state.acknowledgeFlutter()
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 0), "deadlineExceeded")
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "deadlineExceeded")
  }
}
