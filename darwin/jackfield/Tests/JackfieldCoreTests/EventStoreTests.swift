import Foundation
import SQLite3
import XCTest
@testable import JackfieldCore

final class EventStoreTests: XCTestCase {
  func testReplayQueryCompletionRejectsSQLiteReadFailures() throws {
    XCTAssertNoThrow(try EventStore.requireQueryCompleted(SQLITE_DONE))
    for status in [SQLITE_BUSY, SQLITE_IOERR] {
      XCTAssertThrowsError(try EventStore.requireQueryCompleted(status)) { error in
        XCTAssertEqual(error as? JackfieldCoreError, .platformFailure)
      }
    }
  }

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

  func testSaveEndedKeepsFlutterTerminalEventWhenCallbackOutboxIsFull() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio"))
    let occupying = try WireEnvelope.ended(callId: "other-call", eventId: "occupying", sequence: 0,
                                           occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(occupying)

    let ended = try await store.saveEnded(callId: "call-1", eventId: "terminal", reason: "local",
                                          at: Date(timeIntervalSince1970: 101))
    let reopened = try EventStore(path: path)
    let snapshot = try await reopened.snapshot(callId: "call-1")
    let flutter = try await reopened.pendingFlutter()
    let http = try await reopened.pendingHTTP()
    let ready = try await reopened.readyHTTP(at: Date(timeIntervalSince1970: 200))
    let pendingCount = try await reopened.pendingHTTPCount()
    let droppedCount = try await reopened.httpCapacityDroppedCount()
    XCTAssertEqual(snapshot?.state, "ended")
    XCTAssertEqual(ended.eventId, "terminal")
    XCTAssertEqual(flutter.map(\.eventId), ["terminal", "occupying"])
    XCTAssertEqual(http.map(\.eventId), ["occupying"])
    XCTAssertEqual(ready.map(\.eventId), ["occupying"])
    XCTAssertEqual(pendingCount, 1)
    XCTAssertEqual(droppedCount, 1)
    try await reopened.acknowledgeHTTP(["occupying"])
    let readyAfterAck = try await reopened.readyHTTP(at: Date(timeIntervalSince1970: 201))
    let nextWake = try await reopened.nextHTTPWake()
    XCTAssertTrue(readyAfterAck.isEmpty)
    XCTAssertNil(nextWake)
  }

  func testTerminalHTTPAdmissionUsesAvailableCapacityAndRespectsDisabledCallbacks() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio"))
    _ = try await store.saveEnded(callId: "call-1", eventId: "queued", reason: "remote",
                                  at: Date(timeIntervalSince1970: 100))
    let pendingBeforeDisable = try await store.pendingHTTP()
    XCTAssertEqual(pendingBeforeDisable.map(\.eventId), ["queued"])
    try await store.disableHTTP()
    try await store.save(snapshot: CallRecord(callId: "call-2", state: "ringing", media: "audio"))
    _ = try await store.saveEnded(callId: "call-2", eventId: "disabled", reason: "local",
                                  at: Date(timeIntervalSince1970: 101))
    let reopened = try EventStore(path: path)
    let flutter = try await reopened.pendingFlutter()
    let http = try await reopened.pendingHTTP()
    let dropped = try await reopened.httpCapacityDroppedCount()
    XCTAssertEqual(flutter.map(\.eventId), ["queued", "disabled"])
    XCTAssertTrue(http.isEmpty)
    XCTAssertEqual(dropped, 0)
  }

  func testLoweringCallbackLimitKeepsOldestPendingRowsAndFlutterReceipts() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 4, endpoint: "https://example.test/hook", ttl: 60)
    for index in 1...4 {
      let event = try WireEnvelope.ended(callId: "call-\(index)", eventId: "event-\(index)", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: Double(100 + index)), reason: "remote")
      try await store.append(event)
    }
    try await store.acknowledgeFlutter(["event-3"])

    try await store.configureHTTP(limit: 2)
    let reopened = try EventStore(path: path)
    let configuration = try await reopened.httpConfiguration()
    let pending = try await reopened.pendingHTTP()
    let pendingCount = try await reopened.pendingHTTPCount()
    let droppedCount = try await reopened.httpCapacityDroppedCount()
    let flutter = try await reopened.pendingFlutter()
    let thirdCall = try await reopened.allEvents(for: "call-3")
    let fourthCall = try await reopened.allEvents(for: "call-4")
    let ready = try await reopened.readyHTTP(at: Date(timeIntervalSince1970: 200))
    XCTAssertEqual(configuration?.limit, 2)
    XCTAssertEqual(pending.map(\.eventId), ["event-1", "event-2"])
    XCTAssertEqual(pendingCount, 2)
    XCTAssertEqual(droppedCount, 2)
    XCTAssertEqual(flutter.map(\.eventId), ["event-1", "event-2", "event-4"])
    XCTAssertEqual(thirdCall.map(\.eventId), ["event-3"])
    XCTAssertEqual(fourthCall.map(\.eventId), ["event-4"])
    XCTAssertEqual(ready.map(\.eventId), ["event-1", "event-2"])

    try await reopened.acknowledgeFlutter(["event-4"])
    let afterFourthFlutterACK = try await reopened.httpCapacityDroppedCount()
    XCTAssertEqual(afterFourthFlutterACK, 1)
    try await reopened.acknowledgeFlutter(["event-3"])
    let afterAllFlutterACKs = try await reopened.httpCapacityDroppedCount()
    XCTAssertEqual(afterAllFlutterACKs, 0)

    try await reopened.acknowledgeHTTP(["event-1"])
    let afterHTTPAck = try await reopened.pendingHTTP()
    XCTAssertEqual(afterHTTPAck.map(\.eventId), ["event-2"])
    let replacement = try WireEnvelope.ended(callId: "call-5", eventId: "event-5", sequence: 0,
                                              occurredAt: Date(timeIntervalSince1970: 105), reason: "local")
    try await reopened.append(replacement)
    let afterReplacement = try await reopened.pendingHTTP()
    XCTAssertEqual(afterReplacement.map(\.eventId), ["event-2", "event-5"])
  }

  func testFlutterAckRetiresCapacityDropFromActiveDiagnostics() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    try await store.save(snapshot: CallRecord(callId: "call-1", state: "ringing", media: "audio"))
    _ = try await store.saveEnded(callId: "call-1", eventId: "event-1", reason: "remote", at: Date())
    try await store.save(snapshot: CallRecord(callId: "call-2", state: "ringing", media: "audio"))
    _ = try await store.saveEnded(callId: "call-2", eventId: "event-2", reason: "remote", at: Date())
    let beforeACK = try await store.httpCapacityDroppedCount()
    XCTAssertEqual(beforeACK, 1)
    try await store.acknowledgeFlutter(["event-2"])
    let afterACK = try await store.httpCapacityDroppedCount()
    let pending = try await store.pendingHTTP()
    let retainedEvent = try await store.allEvents(for: "call-2")
    XCTAssertEqual(afterACK, 0)
    XCTAssertEqual(pending.map(\.eventId), ["event-1"])
    XCTAssertEqual(retainedEvent.map(\.eventId), ["event-2"])
  }

  func testUnknownFlutterAckDoesNotFreeHTTPAdmissionCapacity() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1)
    let occupying = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                            occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(occupying)
    try await store.acknowledgeFlutter(["unknown-event"])
    let stillFull = try await store.isHTTPAtCapacity()
    XCTAssertTrue(stillFull)
    try await store.save(snapshot: CallRecord(callId: "call-2", state: "ringing", media: "audio"))
    _ = try await store.saveEnded(callId: "call-2", eventId: "event-2", reason: "remote", at: Date())
    try await store.acknowledgeFlutter(["unknown-event", "event-1"])
    let droppedAfterUnrelatedACK = try await store.httpCapacityDroppedCount()
    XCTAssertEqual(droppedAfterUnrelatedACK, 1)
    try await store.acknowledgeHTTP(["event-1"])
    let afterDelivery = try await store.isHTTPAtCapacity()
    XCTAssertFalse(afterDelivery)
  }

  func testCachedCandidateDroppedDuringInventoryWaitCannotStartHTTPTask() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 2, credentialFingerprint: "same", endpoint: "https://example.test/hook", ttl: 300)
    for index in 1...2 {
      let event = try WireEnvelope.ended(callId: "call-\(index)", eventId: "event-\(index)", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: Double(100 + index)), reason: "remote")
      try await store.append(event)
    }
    let cached = try await store.readyHTTP(at: Date(timeIntervalSince1970: 200))
    XCTAssertEqual(cached.map(\.eventId), ["event-1", "event-2"])
    let inventoryReached = expectation(description: "dispatcher is waiting for URLSession task inventory")
    let gate = HTTPInventoryGate()
    let submissions = HTTPSubmissionRecorder()
    let preparedStale = try await store.prepareHTTPDispatch(eventId: cached[1].eventId,
                                                             at: Date(timeIntervalSince1970: 200))
    let staleTicket = try XCTUnwrap(preparedStale)
    let dispatch = Task {
      inventoryReached.fulfill()
      await gate.wait()
      return try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: staleTicket,
                                                                    clock: { Date(timeIntervalSince1970: 200) }) {
        submissions.record(staleTicket.event.eventId)
      }
    }
    await fulfillment(of: [inventoryReached], timeout: 2)
    try await store.configureHTTP(limit: 1)
    await gate.open()
    let submitted = try await dispatch.value
    XCTAssertFalse(submitted)
    XCTAssertTrue(submissions.ids.isEmpty)
    let preparedRetained = try await store.prepareHTTPDispatch(eventId: "event-1",
                                                                at: Date(timeIntervalSince1970: 200))
    let retainedTicket = try XCTUnwrap(preparedRetained)
    let retainedSubmitted = try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: retainedTicket,
                                                                                  clock: { Date(timeIntervalSince1970: 200) }) {
      submissions.record(retainedTicket.event.eventId)
    }
    XCTAssertTrue(retainedSubmitted)
    XCTAssertEqual(submissions.ids, ["event-1"])
    let pending = try await store.pendingHTTP()
    let flutter = try await store.pendingFlutter()
    XCTAssertEqual(pending.map(\.eventId), ["event-1"])
    XCTAssertEqual(flutter.map(\.eventId), ["event-1", "event-2"])
  }

  func testStaleExpiryCannotEraseCapacityDropDiagnostic() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 2)
    for index in 1...2 {
      let event = try WireEnvelope.ended(callId: "call-\(index)", eventId: "event-\(index)", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: Double(100 + index)), reason: "remote")
      try await store.append(event)
    }
    try await store.configureHTTP(limit: 1)
    try await store.markHTTPTerminal("event-2")
    let drops = try await store.httpCapacityDroppedCount()
    XCTAssertEqual(drops, 1)
  }

  func testFailedDispatchPreparationKeepsHTTPEventPending() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "same", endpoint: "https://example.test/hook", ttl: 300)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    let prepared = try await store.prepareHTTPDispatch(eventId: "event-1",
                                                       at: Date(timeIntervalSince1970: 150))
    let ticket = try XCTUnwrap(prepared)
    // Simulate file or URLSession preparation failing before confirmation.
    XCTAssertEqual(ticket.event.eventId, "event-1")
    let pending = try await store.pendingHTTP()
    XCTAssertEqual(pending.map(\.eventId), ["event-1"])
    let retry = try await store.prepareHTTPDispatch(eventId: "event-1", at: Date(timeIntervalSince1970: 151))
    XCTAssertNotNil(retry)
  }

  func testShorterTTLConfiguredDuringInventoryWaitExpiresCachedCandidate() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "same", endpoint: "https://example.test/hook", ttl: 300)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    let cached = try await store.readyHTTP(at: Date(timeIntervalSince1970: 150))
    XCTAssertEqual(cached.map(\.eventId), ["event-1"])
    let inventoryReached = expectation(description: "dispatcher is waiting for URLSession task inventory")
    let gate = HTTPInventoryGate()
    let submissions = HTTPSubmissionRecorder()
    let preparedStale = try await store.prepareHTTPDispatch(eventId: cached[0].eventId,
                                                             at: Date(timeIntervalSince1970: 150))
    let staleTicket = try XCTUnwrap(preparedStale)
    let dispatch = Task {
      inventoryReached.fulfill()
      await gate.wait()
      return try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: staleTicket,
                                                                    clock: { Date(timeIntervalSince1970: 150) }) {
        submissions.record(staleTicket.event.eventId)
      }
    }
    await fulfillment(of: [inventoryReached], timeout: 2)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "same", endpoint: "https://example.test/hook", ttl: 40)
    await gate.open()
    let submitted = try await dispatch.value
    let pending = try await store.pendingHTTP()
    let flutter = try await store.pendingFlutter()
    XCTAssertFalse(submitted)
    XCTAssertTrue(submissions.ids.isEmpty)
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(flutter.map(\.eventId), ["event-1"])
  }

  func testRotatedEndpointAndCredentialDuringInventoryWaitRejectsStaleRequest() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "old", endpoint: "https://old.example.test/hook", ttl: 300)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    let cached = try await store.readyHTTP(at: Date(timeIntervalSince1970: 150))
    XCTAssertEqual(cached.map(\.eventId), ["event-1"])
    let inventoryReached = expectation(description: "dispatcher is waiting for URLSession task inventory")
    let gate = HTTPInventoryGate()
    let submissions = HTTPSubmissionRecorder()
    let preparedStale = try await store.prepareHTTPDispatch(eventId: cached[0].eventId,
                                                             at: Date(timeIntervalSince1970: 150))
    let staleTicket = try XCTUnwrap(preparedStale)
    let staleDispatch = Task {
      inventoryReached.fulfill()
      await gate.wait()
      return try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: staleTicket,
                                                                    clock: { Date(timeIntervalSince1970: 150) }) {
        submissions.record("\(staleTicket.event.eventId)|\(staleTicket.configuration.endpoint)")
      }
    }
    await fulfillment(of: [inventoryReached], timeout: 2)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "new", endpoint: "https://new.example.test/hook", ttl: 300)
    await gate.open()
    let staleSubmitted = try await staleDispatch.value
    XCTAssertFalse(staleSubmitted)
    XCTAssertTrue(submissions.ids.isEmpty)
    let preparedCurrent = try await store.prepareHTTPDispatch(eventId: "event-1",
                                                               at: Date(timeIntervalSince1970: 150))
    let currentTicket = try XCTUnwrap(preparedCurrent)
    let currentDispatch = try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: currentTicket,
                                                                                clock: { Date(timeIntervalSince1970: 150) }) {
      submissions.record("\(currentTicket.event.eventId)|\(currentTicket.configuration.endpoint)")
    }
    XCTAssertTrue(currentDispatch)
    XCTAssertEqual(currentTicket.configuration.endpoint, "https://new.example.test/hook")
    XCTAssertEqual(submissions.ids, ["event-1|https://new.example.test/hook"])
  }

  func testStalledTaskCreationDoesNotBlockCallEventStorage() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 2, credentialFingerprint: "same", endpoint: "https://example.test/hook", ttl: 300)
    let first = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(first)
    let prepared = try await store.prepareHTTPDispatch(eventId: "event-1", at: Date(timeIntervalSince1970: 150))
    let ticket = try XCTUnwrap(prepared)
    let creationReached = expectation(description: "URLSession task creation stalled")
    let writeCompleted = expectation(description: "CallKit event persists while task creation is stalled")
    let gate = HTTPInventoryGate()
    let dispatch = Task {
      creationReached.fulfill()
      await gate.wait()
      return try await store.confirmHTTPDispatch(ticket, at: Date(timeIntervalSince1970: 150))
    }
    await fulfillment(of: [creationReached], timeout: 2)
    let writer = Task {
      let second = try WireEnvelope.ended(callId: "call-2", eventId: "event-2", sequence: 0,
                                          occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
      try await store.append(second)
      writeCompleted.fulfill()
    }
    await fulfillment(of: [writeCompleted], timeout: 2)
    await gate.open()
    try await writer.value
    let permitted = try await dispatch.value
    XCTAssertTrue(permitted)
    let flutter = try await store.pendingFlutter()
    XCTAssertEqual(flutter.map(\.eventId), ["event-1", "event-2"])
  }

  func testConfigurationWaitsForResumeCriticalSectionButEventWritesDoNot() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 2, credentialFingerprint: "old",
                                  endpoint: "https://old.example.test/hook", ttl: 300)
    let first = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(first)
    let prepared = try await store.prepareHTTPDispatch(eventId: "event-1", at: Date(timeIntervalSince1970: 150))
    let ticket = try XCTUnwrap(prepared)
    let enqueueEntered = expectation(description: "synchronous URLSession resume section entered")
    let resumeGate = DispatchSemaphore(value: 0)
    let dispatch = Task {
      try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: ticket,
                                                            clock: { Date(timeIntervalSince1970: 150) }) {
        enqueueEntered.fulfill()
        resumeGate.wait()
      }
    }
    await fulfillment(of: [enqueueEntered], timeout: 2)
    let configuring = expectation(description: "configuration request began")
    let rotation = Task {
      configuring.fulfill()
      try await store.configureHTTP(limit: 2, credentialFingerprint: "new",
                                    endpoint: "https://new.example.test/hook", ttl: 300)
    }
    await fulfillment(of: [configuring], timeout: 2)
    let second = try WireEnvelope.ended(callId: "call-2", eventId: "event-2", sequence: 0,
                                        occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    try await store.append(second)
    let before = try await store.httpConfiguration()
    XCTAssertEqual(before?.endpoint, "https://old.example.test/hook")
    resumeGate.signal()
    let submitted = try await dispatch.value
    XCTAssertTrue(submitted)
    try await rotation.value
    let after = try await store.httpConfiguration()
    XCTAssertEqual(after?.endpoint, "https://new.example.test/hook")
    let flutter = try await store.pendingFlutter()
    XCTAssertEqual(flutter.map(\.eventId), ["event-1", "event-2"])
  }

  func testDisableAfterPreparationPreventsResumeAndPreservesFlutterEvent() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "same",
                                  endpoint: "https://example.test/hook", ttl: 300)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    let prepared = try await store.prepareHTTPDispatch(eventId: "event-1", at: Date(timeIntervalSince1970: 150))
    let ticket = try XCTUnwrap(prepared)
    try await store.disableHTTP()
    let submissions = HTTPSubmissionRecorder()
    let permitted = try await store.dispatchCoordination.enqueueIfCurrent(store: store, ticket: ticket,
                                                                          clock: { Date(timeIntervalSince1970: 150) }) {
      submissions.record(ticket.event.eventId)
    }
    XCTAssertFalse(permitted)
    XCTAssertTrue(submissions.ids.isEmpty)
    let pending = try await store.pendingHTTP()
    let flutter = try await store.pendingFlutter()
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(flutter.map(\.eventId), ["event-1"])
  }

  func testTTLExpiringWhileEnqueueWaitsForCoordinationPreventsResume() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 1, credentialFingerprint: "same",
                                  endpoint: "https://example.test/hook", ttl: 60)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 0,
                                       occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    let prepared = try await store.prepareHTTPDispatch(eventId: "event-1", at: Date(timeIntervalSince1970: 150))
    let ticket = try XCTUnwrap(prepared)
    let clock = HTTPMutableClock(Date(timeIntervalSince1970: 150))
    let submissions = HTTPSubmissionRecorder()
    let coordination = store.dispatchCoordination
    await coordination.acquire()
    let started = expectation(description: "dispatch attempted while coordination held")
    let dispatch = Task {
      started.fulfill()
      return try await coordination.enqueueIfCurrent(store: store, ticket: ticket, clock: { clock.read() }) {
        submissions.record(ticket.event.eventId)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    var queued = 0
    for _ in 0..<10_000 {
      queued = await coordination.pendingAcquisitions
      if queued > 0 { break }
      await Task.yield()
    }
    XCTAssertEqual(queued, 1)
    clock.set(Date(timeIntervalSince1970: 161))
    await coordination.release()
    let permitted = try await dispatch.value
    XCTAssertFalse(permitted)
    XCTAssertTrue(submissions.ids.isEmpty)
    let pending = try await store.pendingHTTP()
    let flutter = try await store.pendingFlutter()
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(flutter.map(\.eventId), ["event-1"])
  }
}

private actor HTTPInventoryGate {
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}

private final class HTTPSubmissionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var submitted: [String] = []

  func record(_ id: String) {
    lock.lock(); defer { lock.unlock() }
    submitted.append(id)
  }

  var ids: [String] {
    lock.lock(); defer { lock.unlock() }
    return submitted
  }
}

private final class HTTPMutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ date: Date) { current = date }

  func read() -> Date {
    lock.lock(); defer { lock.unlock() }
    return current
  }

  func set(_ date: Date) {
    lock.lock(); defer { lock.unlock() }
    current = date
  }
}
