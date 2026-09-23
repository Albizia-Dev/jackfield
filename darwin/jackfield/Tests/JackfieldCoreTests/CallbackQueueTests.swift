import Foundation
import XCTest
@testable import JackfieldCore

final class CallbackQueueTests: XCTestCase {
  func testAuthenticationPauseSurvivesReopenAndRotationResumes() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 100, credentialFingerprint: "old")
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(), reason: "remote")
    try await store.append(event)
    let queue = CallbackQueue(store: store)
    try await queue.recordResponse(eventId: "event-1", status: 401, at: Date())
    let reopened = try EventStore(path: path)
    let paused = try await reopened.httpPausedForAuthentication()
    XCTAssertTrue(paused)
    let ready = try await CallbackQueue(store: reopened).ready(at: Date())
    XCTAssertTrue(ready.isEmpty)
    try await reopened.configureHTTP(limit: 100, credentialFingerprint: "old")
    try await reopened.resumeHTTPAfterCredentialRotation()
    let unchanged = try await CallbackQueue(store: reopened).ready(at: Date())
    XCTAssertTrue(unchanged.isEmpty)
    try await reopened.configureHTTP(limit: 100, credentialFingerprint: "new")
    try await reopened.resumeHTTPAfterCredentialRotation()
    let resumed = try await CallbackQueue(store: reopened).ready(at: Date())
    XCTAssertEqual(resumed.map(\.eventId), ["event-1"])
  }

  func testDelayedEventBlocksLaterEventForSameCall() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let first = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    let second = try WireEnvelope.ended(callId: "call-1", eventId: "event-2", sequence: 1, occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    let other = try WireEnvelope.ended(callId: "call-2", eventId: "event-3", sequence: 0, occurredAt: Date(timeIntervalSince1970: 102), reason: "remote")
    try await store.append(first); try await store.append(second); try await store.append(other)
    try await store.scheduleHTTP("event-1", at: Date(timeIntervalSince1970: 200))
    let ready = try await CallbackQueue(store: store).ready(at: Date(timeIntervalSince1970: 150))
    XCTAssertEqual(ready.map(\.eventId), ["event-3"])
  }

  func testConfiguredOutboxLimitRejectsAdmissionWithoutSavingEvent() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    let first = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(), reason: "local")
    let second = try WireEnvelope.ended(callId: "call-2", eventId: "event-2", sequence: 0, occurredAt: Date(), reason: "remote")
    try await store.append(first)
    do { try await store.append(second); XCTFail("Full outbox must reject admission") }
    catch JackfieldCoreError.storageFull { }
    let flutter = try await store.pendingFlutter()
    XCTAssertEqual(flutter.map(\.eventId), ["event-1"])
  }

  func testRetryBackoffGrowsAndCapsAtFifteenMinutes() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    try await store.append(event)
    let queue = CallbackQueue(store: store)
    try await queue.recordResponse(eventId: "event-1", status: 503, at: Date(timeIntervalSince1970: 100))
    try await queue.recordResponse(eventId: "event-1", status: 503, at: Date(timeIntervalSince1970: 101))
    let tooEarly = try await queue.ready(at: Date(timeIntervalSince1970: 102))
    XCTAssertTrue(tooEarly.isEmpty)
    let due = try await queue.ready(at: Date(timeIntervalSince1970: 103))
    XCTAssertEqual(due.map(\.eventId), ["event-1"])
    try await queue.recordResponse(eventId: "event-1", status: 429, at: Date(timeIntervalSince1970: 103), retryAfter: 5000)
    let capped = try await queue.ready(at: Date(timeIntervalSince1970: 1003))
    XCTAssertEqual(capped.map(\.eventId), ["event-1"])
  }

  func testDisablingCallbacksKeepsFlutterReceiptOnly() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.disableHTTP()
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(), reason: "remote")
    try await store.append(event)
    let flutter = try await store.pendingFlutter()
    let http = try await store.pendingHTTP()
    XCTAssertEqual(flutter.map(\.eventId), ["event-1"])
    XCTAssertTrue(http.isEmpty)
  }

  func testCallbackDestinationSurvivesReopen() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 7, credentialFingerprint: "fingerprint", endpoint: "https://example.test/hook", ttl: 60)
    let reopened = try EventStore(path: path)
    let config = try await reopened.httpConfiguration()
    XCTAssertEqual(config?.endpoint, "https://example.test/hook")
    XCTAssertEqual(config?.ttl, 60)
    XCTAssertEqual(config?.limit, 7)
  }
}
