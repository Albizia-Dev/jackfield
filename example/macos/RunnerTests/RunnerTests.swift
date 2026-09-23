import FlutterMacOS
import XCTest

@testable import jackfield

final class RunnerTests: XCTestCase {
  // Flutter's generated registrant calls this method from a synchronous,
  // nonisolated function. Type checking this reference protects that contract.
  func testPluginRegistrationSignatureIsNonisolated() {
    let register: (FlutterPluginRegistrar) -> Void = JackfieldPlugin.register(with:)
    withExtendedLifetime(register) {}
  }
}
