import Foundation
import XCTest
@testable import JackfieldCore

@MainActor
final class DarwinEventReplaySessionTests: XCTestCase {
  func testDurableReplayPrecedesLiveEventSavedWhileReadIsSuspended() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let old = try WireEnvelope.ended(callId: "call-1", eventId: "old", sequence: 0,
                                      occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(old)
    let loaded = expectation(description: "durable read completed")
    let delivered = expectation(description: "both events delivered")
    delivered.expectedFulfillmentCount = 2
    let gate = AsyncStream<Void>.makeStream()
    let session = DarwinEventReplaySession(loadPending: {
      let pending = try await store.pendingFlutter()
      loaded.fulfill()
      for await _ in gate.stream { break }
      return pending
    })
    var eventIds: [String] = []
    session.start(onEvent: { event in eventIds.append(event.eventId); delivered.fulfill() },
                  onFailure: { XCTFail("Durable read must succeed") })
    await fulfillment(of: [loaded], timeout: 3)

    let live = try WireEnvelope.ended(callId: "call-1", eventId: "live", sequence: 1,
                                       occurredAt: Date(timeIntervalSince1970: 101), reason: "local")
    try await store.append(live)
    session.publish(live)
    XCTAssertTrue(eventIds.isEmpty)
    gate.continuation.yield(())
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertEqual(eventIds, ["old", "live"])
    session.publish(live)
    XCTAssertEqual(eventIds, ["old", "live"])
  }

  func testFailedReadClosesListenerAndNextSubscriptionReplaysDurableEvents() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    let event = try WireEnvelope.ended(callId: "call-1", eventId: "terminal", sequence: 0,
                                        occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    try await store.append(event)
    var failNextRead = true
    let session = DarwinEventReplaySession(loadPending: {
      if failNextRead { failNextRead = false; throw JackfieldCoreError.platformFailure }
      return try await store.pendingFlutter()
    })
    let failed = expectation(description: "first listener closed on read error")
    var firstEvents: [String] = []
    session.start(onEvent: { firstEvents.append($0.eventId) }, onFailure: { failed.fulfill() })
    session.publish(event)
    await fulfillment(of: [failed], timeout: 3)
    XCTAssertTrue(firstEvents.isEmpty)

    let replayed = expectation(description: "later subscription replayed event")
    var secondEvents: [String] = []
    session.start(onEvent: { secondEvents.append($0.eventId); replayed.fulfill() },
                  onFailure: { XCTFail("Second read must succeed") })
    await fulfillment(of: [replayed], timeout: 3)
    XCTAssertEqual(secondEvents, ["terminal"])
  }

  func testCancelledReadCannotEmitIntoReplacementListener() async throws {
    let old = try WireEnvelope.ended(callId: "call-1", eventId: "old", sequence: 0,
                                      occurredAt: Date(timeIntervalSince1970: 100), reason: "remote")
    let firstLoaded = expectation(description: "first read started")
    let firstReturned = expectation(description: "first read returned")
    let replacementDelivered = expectation(description: "replacement replay completed")
    let gate = AsyncStream<Void>.makeStream()
    var reads = 0
    let session = DarwinEventReplaySession(loadPending: {
      reads += 1
      if reads == 1 {
        firstLoaded.fulfill()
        for await _ in gate.stream { break }
        firstReturned.fulfill()
      }
      return [old]
    })
    var oldListenerEvents: [String] = []
    var replacementEvents: [String] = []
    session.start(onEvent: { oldListenerEvents.append($0.eventId) }, onFailure: { XCTFail("No read failure expected") })
    await fulfillment(of: [firstLoaded], timeout: 3)
    session.cancel()
    session.start(onEvent: { replacementEvents.append($0.eventId); replacementDelivered.fulfill() },
                  onFailure: { XCTFail("No read failure expected") })
    await fulfillment(of: [replacementDelivered], timeout: 3)
    gate.continuation.yield(())
    await fulfillment(of: [firstReturned], timeout: 3)
    await Task.yield()
    XCTAssertTrue(oldListenerEvents.isEmpty)
    XCTAssertEqual(replacementEvents, ["old"])
  }
}
