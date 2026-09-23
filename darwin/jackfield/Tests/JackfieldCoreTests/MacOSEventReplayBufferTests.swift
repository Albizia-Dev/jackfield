import Foundation
import XCTest
@testable import JackfieldCore

final class MacOSEventReplayBufferTests: XCTestCase {
  func testPendingEventPrecedesLiveEventDuringNewSubscription() throws {
    let pending = try WireEnvelope.ended(callId: "call-1", eventId: "event-0", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    let live = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 1,
                                      occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    var buffer = MacOSEventReplayBuffer()
    let generation = buffer.begin()
    XCTAssertTrue(buffer.publish(live).isEmpty)
    XCTAssertEqual(buffer.finish(generation: generation, pending: [pending, live]).map(\.eventId), ["event-0", "event-1"])
    XCTAssertTrue(buffer.publish(live).isEmpty)
    XCTAssertTrue(buffer.drain(generation: generation).isEmpty)
    XCTAssertTrue(buffer.publish(live).isEmpty)
  }

  func testCancelledReplayCannotEmitIntoReplacementListener() throws {
    let old = try WireEnvelope.ended(callId: "call-1", eventId: "old", sequence: 0,
                                     occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    var buffer = MacOSEventReplayBuffer()
    let first = buffer.begin()
    buffer.cancel()
    let second = buffer.begin()
    XCTAssertTrue(buffer.finish(generation: first, pending: [old]).isEmpty)
    XCTAssertEqual(buffer.finish(generation: second, pending: [old]).map(\.eventId), ["old"])
    XCTAssertTrue(buffer.drain(generation: second).isEmpty)
  }

  func testLiveEventArrivingDuringReplayEmissionIsDrainedAfterPending() throws {
    let pending = try WireEnvelope.ended(callId: "call-1", eventId: "event-0", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    let live = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 1,
                                      occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    var buffer = MacOSEventReplayBuffer()
    let generation = buffer.begin()
    XCTAssertEqual(buffer.finish(generation: generation, pending: [pending]).map(\.eventId), ["event-0"])
    XCTAssertTrue(buffer.publish(live).isEmpty)
    XCTAssertEqual(buffer.drain(generation: generation).map(\.eventId), ["event-1"])
    XCTAssertTrue(buffer.drain(generation: generation).isEmpty)
  }

  func testFailedReplayDropsBufferedLiveEventsUntilNewSubscription() throws {
    let pending = try WireEnvelope.ended(callId: "call-1", eventId: "event-0", sequence: 0,
                                         occurredAt: Date(timeIntervalSince1970: 100), reason: "local")
    let live = try WireEnvelope.ended(callId: "call-1", eventId: "event-1", sequence: 1,
                                      occurredAt: Date(timeIntervalSince1970: 101), reason: "remote")
    var buffer = MacOSEventReplayBuffer()
    let failed = buffer.begin()
    XCTAssertTrue(buffer.publish(live).isEmpty)

    XCTAssertTrue(buffer.fail(generation: failed))
    XCTAssertFalse(buffer.isCurrent(failed))
    XCTAssertTrue(buffer.finish(generation: failed, pending: []).isEmpty)
    XCTAssertTrue(buffer.drain(generation: failed).isEmpty)

    let replacement = buffer.begin()
    XCTAssertFalse(buffer.fail(generation: failed))
    XCTAssertEqual(buffer.finish(generation: replacement, pending: [pending, live]).map(\.eventId),
                   ["event-0", "event-1"])
    XCTAssertTrue(buffer.drain(generation: replacement).isEmpty)
  }
}
