import Foundation
import XCTest
@testable import JackfieldCore

final class EventStoreTests: XCTestCase {
  func testAppendSurvivesReopenAndReceiptsAreIndependent() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let event = try WireEnvelope.answerRequested(callId: "call-1", eventId: "event-1", sequence: 0, actionId: "action-1", occurredAt: Date(timeIntervalSince1970: 100), deadline: Date(timeIntervalSince1970: 130))
    let store = try EventStore(path: path)
    try await store.append(event)
    let reopened = try EventStore(path: path)
    let before = try await reopened.pendingFlutter()
    XCTAssertEqual(before.map(\.eventId), ["event-1"])
    try await reopened.acknowledgeFlutter(["event-1"])
    let flutter = try await reopened.pendingFlutter()
    let http = try await reopened.pendingHTTP()
    XCTAssertTrue(flutter.isEmpty)
    XCTAssertEqual(http.map(\.eventId), ["event-1"])
    try await reopened.acknowledgeHTTP(["event-1"])
    let after = try await reopened.pendingHTTP()
    XCTAssertTrue(after.isEmpty)
  }

  func testExpiredAnswerPersistsFailureWithoutActivatingCall() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let event = try WireEnvelope.answerRequested(callId: "call-1", eventId: "event-1", sequence: 0, actionId: "action-1", occurredAt: Date(timeIntervalSince1970: 100), deadline: Date(timeIntervalSince1970: 130))
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "connecting", media: "audio", actionId: "action-1", actionDeadline: Date(timeIntervalSince1970: 130)), event: event)
    let receipt = try await store.completeAction("action-1", succeeded: true, at: Date(timeIntervalSince1970: 131))
    XCTAssertEqual(receipt.errorCode, "deadlineExceeded")
    let snapshot = try await store.snapshot(callId: "call-1")
    XCTAssertEqual(snapshot?.state, "failed")
    XCTAssertEqual(snapshot?.actionReceipts.first?.errorCode, "deadlineExceeded")
  }

  func testConflictingDuplicateEventIdIsRejected() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let first = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0, occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    let conflicting = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 1, occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    try await store.append(first)
    do { try await store.append(conflicting); XCTFail("A conflicting replay must fail") }
    catch JackfieldCoreError.protocolFailure { }
    let pending = try await store.pendingFlutter()
    XCTAssertEqual(pending, [first])
  }
}
