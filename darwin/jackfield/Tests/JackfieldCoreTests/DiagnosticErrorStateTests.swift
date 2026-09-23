import XCTest
@testable import JackfieldCore

final class DiagnosticErrorStateTests: XCTestCase {
  func testLaterMethodErrorOverridesUnacknowledgedCapacityDrop() {
    var state = DiagnosticErrorState()
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "storageFull")
    state.record("platformFailure")
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "platformFailure")
  }

  func testFullHTTPQueueKeepsAdmissionStorageError() {
    var state = DiagnosticErrorState()
    state.record("storageFull")
    state.reconcileCapacity(isAtCapacity: true)
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 0), "storageFull")
  }

  func testCapacityReleaseClearsStorageErrorButKeepsLaterError() {
    var state = DiagnosticErrorState()
    state.record("storageFull")
    state.reconcileCapacity(isAtCapacity: false)
    XCTAssertNil(state.visibleError(activeCapacityDrops: 0))

    state.record("storageFull")
    state.record("deadlineExceeded")
    state.reconcileCapacity(isAtCapacity: false)
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 0), "deadlineExceeded")
    XCTAssertEqual(state.visibleError(activeCapacityDrops: 1), "deadlineExceeded")
  }
}
