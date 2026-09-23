import XCTest
@testable import JackfieldCore

final class MacOSCapabilityTests: XCTestCase {
  func testAuthorizedNotificationsAdvertiseOnlyBackedFeatures() {
    let value = MacOSCapabilities.forNotificationAuthorization(.authorized)
    XCTAssertEqual(value.mechanism, "systemNotification")
    XCTAssertEqual(Set(value.features), Set(["incoming", "outgoing", "answer", "reject", "end", "durableEvents", "httpCallbacks"]))
    XCTAssertFalse(value.features.contains("mute"))
    XCTAssertFalse(value.features.contains("hold"))
    XCTAssertFalse(value.features.contains("pushTokens"))
  }

  func testDeniedNotificationsDoNotAdvertiseCallPresentation() {
    let value = MacOSCapabilities.forNotificationAuthorization(.denied)
    XCTAssertEqual(value.mechanism, "unavailable")
    XCTAssertTrue(value.features.isEmpty)
  }
}
