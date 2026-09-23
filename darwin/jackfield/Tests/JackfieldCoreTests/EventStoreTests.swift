import Foundation
import SQLite3
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
    let resolution = try await store.resolveAnswer("action-1", succeeded: true, eventId: "end-1", at: Date(timeIntervalSince1970: 131))
    let receipt = resolution.receipt
    XCTAssertEqual(receipt.errorCode, "deadlineExceeded")
    let snapshot = try await store.snapshot(callId: "call-1")
    XCTAssertEqual(snapshot?.state, "ended")
    XCTAssertEqual(snapshot?.actionReceipts.first?.errorCode, "deadlineExceeded")
    XCTAssertEqual(resolution.ended?.reason, "failed")
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

  func testConcurrentEndedEventsAllocateUniquePerCallSequences() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await withThrowingTaskGroup(of: WireEnvelope.self) { group in
      for index in 0..<20 {
        group.addTask { try await store.appendEnded(callId: "call-1", eventId: "event-\(index)", reason: "remote", at: Date()) }
      }
      var sequences: [Int] = []
      for try await event in group { sequences.append(event.sequence) }
      XCTAssertEqual(sequences.sorted(), Array(0..<20))
    }
    let reopened = try EventStore(path: path)
    let persisted = try await reopened.allEvents(for: "call-1")
    XCTAssertEqual(persisted.map(\.sequence), Array(0..<20))
  }

  func testFutureSchemaIsRejectedAndLegacyZeroMigratesToOne() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var connection: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version=0", nil, nil, nil), SQLITE_OK)
    sqlite3_close(connection)
    let migrated = try EventStore(path: path)
    let version = try await migrated.schemaVersion()
    XCTAssertEqual(version, 1)
    XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
    sqlite3_close(connection)
    do { _ = try EventStore(path: path); XCTFail("Future schema must not open") }
    catch JackfieldCoreError.protocolFailure { }
  }

  func testSystemUUIDSurvivesReopenWithSnapshot() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let id = UUID()
    let store = try EventStore(path: path)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio", systemUUID: id))
    let reopened = try EventStore(path: path)
    let record = try await reopened.snapshot(callId: "call-1")
    XCTAssertEqual(record?.systemUUID, id)
    let mapped = try await reopened.callId(for: id)
    XCTAssertEqual(mapped, "call-1")
  }

  func testAnswerAndEndCommitSequenceWithSnapshotAtomically() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio", systemUUID: UUID()))
    let answer = try await store.saveAnswerRequested(callId: "call-1", eventId: "answer-1", actionId: "action-1", deadline: Date(timeIntervalSince1970: 130), at: Date(timeIntervalSince1970: 100))
    let ended = try await store.saveEnded(callId: "call-1", eventId: "end-1", reason: "remote", at: Date(timeIntervalSince1970: 101))
    XCTAssertEqual([answer.sequence, ended.sequence], [0, 1])
    let record = try await store.snapshot(callId: "call-1")
    XCTAssertEqual(record?.state, "ended")
    let events = try await store.allEvents(for: "call-1")
    XCTAssertEqual(events.map(\.eventId), ["answer-1", "end-1"])
  }

  func testFailedAnswerAtomicallyPersistsReceiptTerminalSnapshotAndEndedForReplay() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio"))
    _ = try await store.saveAnswerRequested(callId: "call-1", eventId: "answer-1", actionId: "action-1", deadline: Date(timeIntervalSince1970: 130), at: Date(timeIntervalSince1970: 100))
    let first = try await store.resolveAnswer("action-1", succeeded: false, eventId: "end-1", at: Date(timeIntervalSince1970: 110))
    XCTAssertFalse(first.receipt.succeeded)
    XCTAssertEqual(first.ended?.reason, "failed")
    XCTAssertEqual(first.ended?.sequence, 1)
    let repeated = try await store.resolveAnswer("action-1", succeeded: false, eventId: "end-2", at: Date(timeIntervalSince1970: 111))
    XCTAssertEqual(repeated.receipt, first.receipt)
    XCTAssertNil(repeated.ended)
    let reopened = try EventStore(path: path)
    let snapshot = try await reopened.snapshot(callId: "call-1")
    let flutter = try await reopened.pendingFlutter()
    let http = try await reopened.pendingHTTP()
    XCTAssertEqual(snapshot?.state, "ended")
    XCTAssertEqual(snapshot?.actionReceipts, [first.receipt])
    XCTAssertEqual(flutter.map(\.eventId), ["answer-1", "end-1"])
    XCTAssertEqual(http.map(\.eventId), ["answer-1", "end-1"])
  }

  func testVersionZeroMigrationRenumbersDuplicateSequencesAndPreservesReceipts() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var connection: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE events (event_id TEXT PRIMARY KEY, call_id TEXT NOT NULL, sequence INTEGER NOT NULL, json BLOB NOT NULL, flutter_ack INTEGER NOT NULL DEFAULT 0, http_state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL DEFAULT 0)", nil, nil, nil), SQLITE_OK)
    let first = try WireEnvelope.answerRequested(callId: "call-1", eventId: "answer-1", sequence: 0, actionId: "action-1", occurredAt: Date(timeIntervalSince1970: 100), deadline: Date(timeIntervalSince1970: 130))
    let second = try WireEnvelope.ended(callId: "call-1", eventId: "end-1", sequence: 0, occurredAt: Date(timeIntervalSince1970: 101), reason: "failed")
    for (event, ack, state, attempts) in [(first, 1, "acknowledged", 2), (second, 0, "pending", 3)] {
      let hex = try JSONEncoder().encode(event).map { String(format: "%02x", $0) }.joined()
      let sql = "INSERT INTO events(event_id,call_id,sequence,json,flutter_ack,http_state,attempts,next_at) VALUES('\(event.eventId)','call-1',0,X'\(hex)',\(ack),'\(state)',\(attempts),123)"
      XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
    }
    sqlite3_close(connection)
    let store = try EventStore(path: path)
    let events = try await store.allEvents(for: "call-1")
    let flutter = try await store.pendingFlutter()
    let http = try await store.pendingHTTP()
    let attempts = try await store.httpAttempts("end-1")
    let version = try await store.schemaVersion()
    XCTAssertEqual(events.map(\.sequence), [0, 1])
    XCTAssertEqual(flutter.map(\.eventId), ["end-1"])
    XCTAssertEqual(http.map(\.eventId), ["end-1"])
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(version, 1)
  }

  func testFailedAnswerPersistsTerminalEventWhenCallbackQueueIsAtAdmissionLimit() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio"))
    _ = try await store.saveAnswerRequested(callId: "call-1", eventId: "answer-1", actionId: "action-1", deadline: Date(timeIntervalSince1970: 130), at: Date(timeIntervalSince1970: 100))
    let resolution = try await store.resolveAnswer("action-1", succeeded: false, eventId: "end-1", at: Date(timeIntervalSince1970: 101))
    let events = try await store.allEvents(for: "call-1")
    XCTAssertEqual(resolution.ended?.reason, "failed")
    XCTAssertEqual(events.map(\.eventId), ["answer-1", "end-1"])
  }
}
