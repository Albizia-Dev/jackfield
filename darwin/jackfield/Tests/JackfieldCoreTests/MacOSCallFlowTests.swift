import Foundation
import XCTest
@testable import JackfieldCore

final class MacOSCallFlowTests: XCTestCase {
  func testAnswerActionSurvivesReopenAndCompletesIndependentlyOfEventAck() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let flow = MacOSCallFlow(store: store)
    let ringing = try await flow.reportIncoming(callId: "call-1", callerId: "caller-1", callerName: "Ada", media: "audio")
    XCTAssertEqual(ringing.state, "ringing")
    let action = try await flow.answer(callId: "call-1", actionId: "action-1", eventId: "event-1", deadline: Date().addingTimeInterval(30))
    XCTAssertEqual(action.type, "answer_requested")
    XCTAssertEqual(action.sequence, 0)

    let reopened = try EventStore(path: path)
    let restored = MacOSCallFlow(store: reopened)
    let completion = try await restored.complete(actionId: "action-1", succeeded: true)
    XCTAssertTrue(completion.receipt.succeeded)
    XCTAssertNil(completion.ended)
    let snapshot = try await reopened.snapshot(callId: "call-1")
    let pending = try await reopened.pendingFlutter()
    XCTAssertEqual(snapshot?.state, "active")
    XCTAssertEqual(pending.map(\.eventId), ["event-1"])
  }

  func testRejectPersistsTerminalEventAndRepeatedEndDoesNotDuplicateIt() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let flow = MacOSCallFlow(store: store)
    _ = try await flow.reportIncoming(callId: "call-1", callerId: "caller-1", callerName: "Ada", media: "audio")
    let first = try await flow.end(callId: "call-1", reason: "rejected")
    XCTAssertEqual(first.event?.reason, "rejected")
    let repeated = try await flow.end(callId: "call-1", reason: "rejected")
    XCTAssertNil(repeated.event)
    let pending = try await store.pendingFlutter()
    XCTAssertEqual(pending.map(\.type), ["ended"])
  }

  func testNotificationRejectSurvivesFullCallbackQueue() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    let flow = MacOSCallFlow(store: store)
    _ = try await flow.reportIncoming(callId: "call-1", callerId: "caller-1", callerName: "Ada", media: "audio")
    _ = try await flow.reportIncoming(callId: "call-2", callerId: "caller-2", callerName: "Lin", media: "audio")
    _ = try await flow.end(callId: "call-1", reason: "rejected")
    let second = try await flow.end(callId: "call-2", reason: "rejected")
    XCTAssertEqual(second.event?.reason, "rejected")
    let pending = try await store.pendingFlutter()
    XCTAssertEqual(pending.count, 2)
  }

  func testEndDuringPendingAnswerPreservesRequestedReasonAndReceipt() async throws {
    for reason in ["rejected", "local", "remote"] {
      let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
      defer { try? FileManager.default.removeItem(atPath: path) }
      let store = try EventStore(path: path)
      let flow = MacOSCallFlow(store: store)
      _ = try await flow.reportIncoming(callId: "call-1", callerId: "caller-1", callerName: "Ada", media: "audio")
      _ = try await flow.answer(callId: "call-1", actionId: "action-1", eventId: "answer-1", deadline: Date().addingTimeInterval(30))

      let ended = try await flow.end(callId: "call-1", reason: reason)
      XCTAssertEqual(ended.event?.reason, reason)
      XCTAssertEqual(ended.record.state, "ended")
      XCTAssertEqual(ended.record.actionReceipts, [ActionReceipt(actionId: "action-1", succeeded: false)])
      let replay = try await store.pendingFlutter()
      XCTAssertEqual(replay.map(\.type), ["answer_requested", "ended"])
      XCTAssertEqual(replay.map(\.sequence), [0, 1])
      let repeatCompletion = try await flow.complete(actionId: "action-1", succeeded: true)
      XCTAssertFalse(repeatCompletion.receipt.succeeded)
      XCTAssertNil(repeatCompletion.ended)
    }
  }

  func testAnswerActionReportsStorageFullWithoutPublishingOrChangingState() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    let flow = MacOSCallFlow(store: store)
    _ = try await flow.reportIncoming(callId: "call-1", callerId: "caller-1", callerName: "Ada", media: "audio")
    _ = try await flow.reportIncoming(callId: "call-2", callerId: "caller-2", callerName: "Lin", media: "audio")
    _ = try await flow.answer(callId: "call-1", actionId: "action-1", eventId: "event-1", deadline: Date().addingTimeInterval(30))

    var diagnostics: [String] = []
    let outcome = await MacOSActionHandling.capture({
      try await flow.answer(callId: "call-2", actionId: "action-2", eventId: "event-2", deadline: Date().addingTimeInterval(30))
    }, onFailure: { diagnostics.append($0) })
    switch outcome {
    case .failure(let code): XCTAssertEqual(code, "storageFull")
    case .success: XCTFail("An unpersisted answer must not be reported as handled")
    }
    let snapshot = try await store.snapshot(callId: "call-2")
    let pending = try await store.pendingFlutter()
    XCTAssertEqual(snapshot?.state, "ringing")
    XCTAssertEqual(pending.map(\.eventId), ["event-1"])
    XCTAssertEqual(diagnostics, ["storageFull"])
  }
}
