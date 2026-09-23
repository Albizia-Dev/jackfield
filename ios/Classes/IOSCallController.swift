import CallKit
import Foundation

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
final class IOSCallController: NSObject, CXProviderDelegate {
  private let provider: CXProvider
  private let callController = CXCallController()
  private let store: EventStore
  private let publish: (WireEnvelope) -> Void
  private var identifiers: [String: UUID] = [:]
  private var callIds: [UUID: String] = [:]
  private var requestedEndReasons: [UUID: String] = [:]

  init(store: EventStore, publish: @escaping (WireEnvelope) -> Void) {
    self.store = store; self.publish = publish
    let config = CXProviderConfiguration(localizedName: "Jackfield")
    config.supportsVideo = true
    config.supportedHandleTypes = [.generic]
    config.maximumCallsPerCallGroup = 1
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  private func uuid(_ callId: String) -> UUID {
    if let existing = identifiers[callId] { return existing }
    let created = UUID(); identifiers[callId] = created; callIds[created] = callId; return created
  }

  func reportIncoming(callId: String, callerId: String, callerName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) { return existing }
    let id = uuid(callId)
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerId)
    update.localizedCallerName = callerName
    update.hasVideo = media == "video"
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      provider.reportNewIncomingCall(with: id, update: update) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    let record = CallRecord(callId: callId, state: "ringing", media: media, callerId: callerId, callerName: callerName)
    try await store.save(snapshot: record)
    return record
  }

  func startOutgoing(callId: String, calleeId: String, calleeName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) { return existing }
    let id = uuid(callId)
    let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: calleeId))
    action.isVideo = media == "video"
    try await request(CXTransaction(action: action))
    let record = CallRecord(callId: callId, state: "connecting", media: media, callerId: calleeId, callerName: calleeName)
    try await store.save(snapshot: record)
    provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
    return record
  }

  func update(callId: String, callerId: String?, callerName: String?, media: String?) async throws -> CallRecord {
    guard var record = try await store.snapshot(callId: callId), !["ended", "failed"].contains(record.state) else { throw JackfieldCoreError.invalidState }
    if let callerId, let callerName { record.callerId = callerId; record.callerName = callerName }
    if let media { record.media = media }
    let update = CXCallUpdate()
    update.localizedCallerName = record.callerName
    update.hasVideo = record.media == "video"
    provider.reportCall(with: uuid(callId), updated: update)
    try await store.save(snapshot: record)
    return record
  }

  func end(callId: String, reason: String) async throws -> CallRecord {
    guard var record = try await store.snapshot(callId: callId) else { throw JackfieldCoreError.invalidState }
    if record.state == "ended" { return record }
    let id = uuid(callId)
    if reason == "local" || reason == "rejected" {
      requestedEndReasons[id] = reason
      try await request(CXTransaction(action: CXEndCallAction(call: id)))
      if let completed = try await store.snapshot(callId: callId), completed.state == "ended" { return completed }
    } else {
      provider.reportCall(with: id, endedAt: Date(), reason: reason == "remote" ? .remoteEnded : .failed)
    }
    record.state = "ended"
    let event = try WireEnvelope.ended(callId: callId, eventId: UUID().uuidString, sequence: try await nextSequence(callId), occurredAt: Date(), reason: reason)
    try await store.save(snapshot: record, event: event)
    publish(event)
    return record
  }

  func complete(actionId: String, succeeded: Bool, at date: Date = Date()) async throws -> ActionReceipt {
    let receipt = try await store.completeAction(actionId, succeeded: succeeded, at: date)
    return receipt
  }

  private func nextSequence(_ callId: String) async throws -> Int {
    let existing = try await store.allEvents(for: callId)
    return (existing.map(\.sequence).max() ?? -1) + 1
  }

  private func request(_ transaction: CXTransaction) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      callController.request(transaction) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  func providerDidReset(_ provider: CXProvider) {
    identifiers.removeAll(); callIds.removeAll(); requestedEndReasons.removeAll()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let callId = callIds[action.callUUID] else { action.fail(); return }
    Task {
      do {
        guard var record = try await store.snapshot(callId: callId), record.state == "ringing" else { action.fail(); return }
        let deadline = Date().addingTimeInterval(30)
        let actionId = UUID().uuidString
        let event = try WireEnvelope.answerRequested(callId: callId, eventId: UUID().uuidString, sequence: try await nextSequence(callId), actionId: actionId, occurredAt: Date(), deadline: deadline)
        record.state = "connecting"; record.actionId = actionId; record.actionDeadline = deadline
        try await store.save(snapshot: record, event: event)
        publish(event)
        action.fulfill()
      } catch { action.fail() }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard let callId = callIds[action.callUUID] else { action.fail(); return }
    let reason = requestedEndReasons.removeValue(forKey: action.callUUID) ?? "local"
    Task {
      do {
        guard var record = try await store.snapshot(callId: callId) else { action.fail(); return }
        if record.state != "ended" {
          record.state = "ended"
          let event = try WireEnvelope.ended(callId: callId, eventId: UUID().uuidString, sequence: try await nextSequence(callId), occurredAt: Date(), reason: reason)
          try await store.save(snapshot: record, event: event)
          publish(event)
        }
        action.fulfill()
      } catch { action.fail() }
    }
  }
}
