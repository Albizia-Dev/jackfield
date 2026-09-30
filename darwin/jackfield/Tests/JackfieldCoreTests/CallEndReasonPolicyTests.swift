import XCTest
@testable import JackfieldCore

final class CallEndReasonPolicyTests: XCTestCase {
  func testSystemDeclineAndHangupAreDistinguished() {
    XCTAssertEqual(CallEndReasonPolicy.systemEnd(requested: nil, state: "ringing"), "rejected")
    XCTAssertEqual(CallEndReasonPolicy.systemEnd(requested: nil, state: "active"), "local")
    XCTAssertEqual(CallEndReasonPolicy.systemEnd(requested: "remote", state: "ringing"), "remote")
  }
}
