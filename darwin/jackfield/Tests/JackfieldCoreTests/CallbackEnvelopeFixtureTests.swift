import Foundation
import XCTest
@testable import JackfieldCore

final class CallbackEnvelopeFixtureTests: XCTestCase {
  func testSharedNativeRequestMatchesCanonicalCallbackFixture() throws {
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: canonicalFixtureURL()))
    guard let object = fixture as? [String: Any], let wire = object["event"] as? [String: Any],
          let callId = wire["callId"] as? String,
          let eventId = wire["eventId"] as? String,
          let actionId = wire["actionId"] as? String,
          let sequence = wire["sequence"] as? Int,
          let occurredAtText = wire["occurredAt"] as? String,
          let deadlineText = wire["deadline"] as? String else {
      XCTFail("Canonical callback fixture has no answer event")
      return
    }
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let occurredAt = dates.date(from: occurredAtText),
          let deadline = dates.date(from: deadlineText) else {
      XCTFail("Canonical callback fixture has invalid timestamps")
      return
    }
    let event = try WireEnvelope.answerRequested(callId: callId, eventId: eventId,
      sequence: sequence, actionId: actionId, occurredAt: occurredAt, deadline: deadline)
    let endpoint = try XCTUnwrap(URL(string: "https://example.test/callback"))

    let request = try event.callbackRequest(to: endpoint, token: "test-token")

    XCTAssertEqual(request.url, endpoint)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), eventId)
    let body = try XCTUnwrap(request.httpBody)
    let actual = try JSONSerialization.jsonObject(with: body)
    XCTAssertEqual(try canonicalJSON(actual), try canonicalJSON(fixture))
    XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-token"))
  }

  private func canonicalFixtureURL() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != directory.deletingLastPathComponent().path {
      let candidate = directory.appendingPathComponent("test/fixtures/callback_answer_requested_v1.json")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      directory.deleteLastPathComponent()
    }
    throw NSError(domain: "JackfieldFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
      "Cannot locate canonical callback fixture from Swift source path"])
  }

  private func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
}
