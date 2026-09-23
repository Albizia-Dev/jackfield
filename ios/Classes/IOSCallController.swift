import CallKit
import Foundation

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
final class IOSCallController: NSObject, CXProviderDelegate {
  private let provider: CXProvider
  private let callController = CXCallController()
  private let callObserver = CXCallObserver()
  private let store: EventStore
  private let publish: (WireEnvelope) -> Void
  private var identifiers: [String: UUID] = [:]
  private var callIds: [UUID: String] = [:]
  private var requestedEndReasons: [UUID: String] = [:]
  private var pendingAnswers: [String: CXAnswerCallAction] = [:]
  private var answerDeadlines: [String: Task<Void, Never>] = [:]

  init(store: EventStore, publish: @escaping (WireEnvelope) -> Void) {
    self.store = store; self.publish = publish
    let config = CXProviderConfiguration(localizedName: "Jackfield")
    config.supportsVideo = true
    config.supportedHandleTypes = [.generic]
    config.maximumCallsPerCallGroup = 1
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: .main)
    Task { await reconcileSystemCalls() }
  }

  private func newUUID(_ callId: String) -> UUID {
    let created = UUID()
    identifiers[callId] = created
    callIds[created] = callId
    return created
  }

  private func existingUUID(_ callId: String) async throws -> UUID {
    guard let record = try await store.snapshot(callId: callId), let saved = record.systemUUID,
          callObserver.calls.contains(where: { $0.uuid == saved && !$0.hasEnded }) else {
      throw JackfieldCoreError.temporarilyUnavailable
    }
    identifiers[callId] = saved
    callIds[saved] = callId
    return saved
  }

  private func knownCallId(_ uuid: UUID) async throws -> String? {
    if let known = callIds[uuid] { return known }
    return try await store.callId(for: uuid)
  }

  func reportIncoming(callId: String, callerId: String, callerName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) {
      _ = try await existingUUID(callId)
      return existing
    }
    let id = newUUID(callId)
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
    let record = CallRecord(callId: callId, state: "ringing", media: media, callerId: callerId, callerName: callerName, systemUUID: id)
    do { try await store.save(snapshot: record) }
    catch { provider.reportCall(with: id, endedAt: Date(), reason: .failed); throw error }
    return record
  }

  func startOutgoing(callId: String, calleeId: String, calleeName: String, media: String) async throws -> CallRecord {
    if let existing = try await store.snapshot(callId: callId) {
      _ = try await existingUUID(callId)
      return existing
    }
    let id = newUUID(callId)
    let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: calleeId))
    action.isVideo = media == "video"
    try await request(CXTransaction(action: action))
    let record = CallRecord(callId: callId, state: "connecting", media: media, callerId: calleeId, callerName: calleeName, systemUUID: id)
    do { try await store.save(snapshot: record) }
    catch { provider.reportCall(with: id, endedAt: Date(), reason: .failed); throw error }
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
    provider.reportCall(with: try await existingUUID(callId), updated: update)
    try await store.save(snapshot: record)
    return record
  }

  func end(callId: String, reason: String) async throws -> CallRecord {
    guard let record = try await store.snapshot(callId: callId) else { throw JackfieldCoreError.invalidState }
    if record.state == "ended" { return record }
    let id = try await existingUUID(callId)
    let hadPendingAnswer = record.actionId.flatMap { pendingAnswers[$0] } != nil
    if let actionId = record.actionId, hadPendingAnswer {
      _ = try await complete(actionId: actionId, succeeded: false)
      return try await store.snapshot(callId: callId) ?? record
    }
    if (reason == "local" || reason == "rejected") && !hadPendingAnswer {
      requestedEndReasons[id] = reason
      try await request(CXTransaction(action: CXEndCallAction(call: id)))
      if let completed = try await store.snapshot(callId: callId), completed.state == "ended" { return completed }
    } else if !hadPendingAnswer {
      provider.reportCall(with: id, endedAt: Date(), reason: reason == "remote" ? .remoteEnded : .failed)
    }
    let event = try await store.saveEnded(callId: callId, eventId: UUID().uuidString, reason: reason, at: Date())
    publish(event)
    return try await store.snapshot(callId: callId) ?? record
  }

  func complete(actionId: String, succeeded: Bool, at date: Date = Date()) async throws -> ActionReceipt {
    let records = try await store.allCallRecords()
    guard let record = records.first(where: { $0.actionId == actionId }) else { throw JackfieldCoreError.invalidState }
    guard let action = pendingAnswers[actionId] else {
      if let receipt = record.actionReceipts.first(where: { $0.actionId == actionId }) { return receipt }
      throw JackfieldCoreError.temporarilyUnavailable
    }
    let resolution = try await store.resolveAnswer(actionId, succeeded: succeeded, eventId: UUID().uuidString, at: date)
    pendingAnswers.removeValue(forKey: actionId)
    answerDeadlines.removeValue(forKey: actionId)?.cancel()
    if let event = resolution.ended { publish(event) }
    let receipt = resolution.receipt
    if receipt.succeeded { action.fulfill() }
    else {
      action.fail()
      if let id = record.systemUUID { provider.reportCall(with: id, endedAt: date, reason: .failed) }
    }
    return receipt
  }

  private func expireAnswer(_ actionId: String, deadline: Date) {
    answerDeadlines[actionId]?.cancel()
    answerDeadlines[actionId] = Task { [weak self] in
      let delay = max(0, deadline.timeIntervalSinceNow + 0.001)
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      _ = try? await self?.complete(actionId: actionId, succeeded: false, at: Date())
    }
  }

  private func reconcileSystemCalls() async {
    guard let records = try? await store.allCallRecords() else { return }
    let observed = Set(callObserver.calls.filter { !$0.hasEnded }.map(\.uuid))
    for record in records where record.state != "ended" {
      if record.state == "failed" {
        if let event = try? await store.saveEnded(callId: record.callId, eventId: UUID().uuidString, reason: "failed", at: Date()) { publish(event) }
        if let id = record.systemUUID, observed.contains(id) { provider.reportCall(with: id, endedAt: Date(), reason: .failed) }
        continue
      }
      guard let id = record.systemUUID, observed.contains(id) else {
        if record.state == "connecting", let actionId = record.actionId,
           !record.actionReceipts.contains(where: { $0.actionId == actionId }) {
          if let resolution = try? await store.resolveAnswer(actionId, succeeded: false, eventId: UUID().uuidString, at: Date()),
             let event = resolution.ended { publish(event) }
          continue
        }
        if let event = try? await store.saveEnded(callId: record.callId, eventId: UUID().uuidString, reason: "failed", at: Date()) { publish(event) }
        continue
      }
      identifiers[record.callId] = id
      callIds[id] = record.callId
      if record.state == "connecting", let actionId = record.actionId,
         !record.actionReceipts.contains(where: { $0.actionId == actionId }) {
        if let resolution = try? await store.resolveAnswer(actionId, succeeded: false, eventId: UUID().uuidString, at: Date()),
           let event = resolution.ended { publish(event) }
        provider.reportCall(with: id, endedAt: Date(), reason: .failed)
      }
    }
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
    for (_, action) in pendingAnswers { action.fail() }
    for (_, timer) in answerDeadlines { timer.cancel() }
    pendingAnswers.removeAll(); answerDeadlines.removeAll()
    identifiers.removeAll(); callIds.removeAll(); requestedEndReasons.removeAll()
    Task { await reconcileSystemCalls() }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) { action.fulfill() }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    Task {
      do {
        guard let callId = try await knownCallId(action.callUUID),
              let record = try await store.snapshot(callId: callId), record.state == "ringing" else { action.fail(); return }
        let deadline = min(action.timeoutDate, Date().addingTimeInterval(30))
        let actionId = UUID().uuidString
        let event = try await store.saveAnswerRequested(callId: callId, eventId: UUID().uuidString, actionId: actionId, deadline: deadline, at: Date())
        pendingAnswers[actionId] = action
        expireAnswer(actionId, deadline: deadline)
        publish(event)
      } catch { action.fail() }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let reason = requestedEndReasons.removeValue(forKey: action.callUUID) ?? "local"
    Task {
      do {
        guard let callId = try await knownCallId(action.callUUID),
              let record = try await store.snapshot(callId: callId) else { action.fail(); return }
        if record.state != "ended" {
          if let actionId = record.actionId, pendingAnswers[actionId] != nil {
            _ = try await complete(actionId: actionId, succeeded: false)
          } else if record.state == "connecting", let actionId = record.actionId,
                    !record.actionReceipts.contains(where: { $0.actionId == actionId }) {
            let resolution = try await store.resolveAnswer(actionId, succeeded: false, eventId: UUID().uuidString, at: Date())
            if let event = resolution.ended { publish(event) }
          } else {
            let event = try await store.saveEnded(callId: callId, eventId: UUID().uuidString, reason: reason, at: Date())
            publish(event)
          }
        }
        action.fulfill()
      } catch { action.fail() }
    }
  }
}
