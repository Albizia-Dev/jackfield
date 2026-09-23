import Foundation
import XCTest
@testable import JackfieldCore

@objc private protocol OptionalForwardingProbe: NSObjectProtocol {
  @objc optional func deliver(_ completion: @escaping () -> Void)
}

private final class MissingForwardingMethod: NSObject, OptionalForwardingProbe {}

private final class ImplementedForwardingMethod: NSObject, OptionalForwardingProbe {
  func deliver(_ completion: @escaping () -> Void) { completion() }
}

final class MacOSDelegateForwardingTests: XCTestCase {
  func testMissingOptionalDelegateMethodCompletesOnce() {
    var completions = 0
    let delegate: OptionalForwardingProbe = MissingForwardingMethod()
    MacOSDelegateForwarding.forward(optionalCall: { delegate.deliver?({ completions += 1 }) }, fallback: { completions += 1 })
    XCTAssertEqual(completions, 1)
  }

  func testImplementedDelegateMethodOwnsCompletionWithoutFallback() {
    var completions = 0
    let delegate: OptionalForwardingProbe = ImplementedForwardingMethod()
    MacOSDelegateForwarding.forward(optionalCall: { delegate.deliver?({ completions += 1 }) }, fallback: { completions += 1 })
    XCTAssertEqual(completions, 1)
  }
}
