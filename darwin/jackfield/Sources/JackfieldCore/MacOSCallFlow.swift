import Foundation

/// Durable call transitions shared by macOS notification actions and Flutter commands.
public struct MacOSCallFlow: Sendable {
  private let store: EventStore

  public init(store: EventStore) { self.store = store }

  public func reportIncoming(callId: String, callerId: String, callerName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) { return existing }
    let record = CallRecord(callId: callId, state: "ringing", media: media, callerId: callerId, callerName: callerName)
    try await store.save(snapshot: record)
    return record
  }

  public func startOutgoing(callId: String, calleeId: String, calleeName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) { return existing }
    let record = CallRecord(callId: callId, state: "connecting", media: media, callerId: calleeId, callerName: calleeName)
    try await store.save(snapshot: record)
    return record
  }

  public func update(callId: String, callerId: String?, callerName: String?, media: String?) async throws -> CallRecord {
    guard var record = try await store.snapshot(callId: callId), record.state != "ended" else { throw JackfieldCoreError.invalidState }
    if let callerId, let callerName { record.callerId = callerId; record.callerName = callerName }
    if let media { record.media = media }
    try await store.save(snapshot: record)
    return record
  }

  public func answer(callId: String, actionId: String, eventId: String, deadline: Date, at date: Date = Date()) async throws -> WireEnvelope {
    try await store.saveAnswerRequested(callId: callId, eventId: eventId, actionId: actionId, deadline: deadline, at: date)
  }

  public func end(callId: String, reason: String, at date: Date = Date()) async throws -> (record: CallRecord, event: WireEnvelope?) {
    guard let record = try await store.snapshot(callId: callId) else { throw JackfieldCoreError.invalidState }
    if record.state == "ended" { return (record, nil) }
    if record.state == "connecting", let actionId = record.actionId,
       !record.actionReceipts.contains(where: { $0.actionId == actionId }) {
      let result = try await store.endPendingAnswer(callId: callId, eventId: UUID().uuidString, reason: reason, at: date)
      return (result.record, result.event)
    }
    let event = try await store.saveEnded(callId: callId, eventId: UUID().uuidString, reason: reason, at: date, admissionCritical: true)
    return (try await store.snapshot(callId: callId) ?? record, event)
  }

  public func complete(actionId: String, succeeded: Bool, at date: Date = Date()) async throws -> (receipt: ActionReceipt, ended: WireEnvelope?) {
    try await store.resolveAnswer(actionId, succeeded: succeeded, eventId: UUID().uuidString, at: date)
  }
}
