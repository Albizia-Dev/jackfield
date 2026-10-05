import CallKit
import CryptoKit
import Foundation
import AVFoundation
import os.log

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
enum JackfieldLog {
  private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "dev.albizia.jackfield",
                                 category: "Jackfield")

  static func info(_ stage: String, callId: String? = nil, detail: String? = nil) {
    write(.info, stage: stage, callId: callId, detail: detail)
  }

  static func error(_ stage: String, callId: String? = nil, error: Error? = nil) {
    write(.error, stage: stage, callId: callId,
          detail: error.map { "error=\(String(describing: type(of: $0))) description=\($0.localizedDescription)" })
  }

  private static func write(_ type: OSLogType, stage: String, callId: String?, detail: String?) {
    var message = "stage=\(stage)"
    if let callId, !callId.isEmpty {
      let digest = SHA256.hash(data: Data(callId.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
      message += " call=\(digest)"
    }
    if let detail, !detail.isEmpty { message += " \(detail)" }
    os_log("%{public}@", log: log, type: type, message)
  }
}

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
  private var ringDeadlines: [String: Task<Void, Never>] = [:]

  init(store: EventStore, publish: @escaping (WireEnvelope) -> Void) {
    self.store = store; self.publish = publish
    let config = CXProviderConfiguration(localizedName: "Jackfield")
    config.supportsVideo = true
    config.supportedHandleTypes = [.generic]
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.includesCallsInRecents = true
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: .main)
    JackfieldLog.info("callkit.provider_ready")
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

  func reportIncoming(callId: String, callerId: String, callerName: String, media: String, expiresAt: Date) async throws -> CallRecord {
    JackfieldLog.info("callkit.report_incoming", callId: callId, detail: "media=\(media)")
    if let existing = try await store.snapshot(callId: callId) {
      if ["ended", "failed"].contains(existing.state) { return existing }
      if existing.state == "ringing", let persistedDeadline = existing.expiresAt, persistedDeadline <= Date() {
        return try await end(callId: callId, reason: "missed")
      }
      _ = try await existingUUID(callId)
      if existing.state == "ringing", let persistedDeadline = existing.expiresAt {
        scheduleRingDeadline(callId, at: persistedDeadline)
      }
      return existing
    }
    guard expiresAt > Date() else { throw JackfieldCoreError.deadlineExceeded }
    guard expiresAt.timeIntervalSinceNow <= 300 else { throw JackfieldCoreError.protocolFailure }
    let id = newUUID(callId)
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerId)
    update.localizedCallerName = callerName
    update.hasVideo = media == "video"
    Self.restrictUnsupportedActions(update)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      provider.reportNewIncomingCall(with: id, update: update) { error in
        if let error {
          JackfieldLog.error("callkit.report_incoming_failed", callId: callId, error: error)
          continuation.resume(throwing: error)
        } else {
          JackfieldLog.info("callkit.incoming_reported", callId: callId)
          continuation.resume()
        }
      }
    }
    let record = CallRecord(callId: callId, state: "ringing", media: media, callerId: callerId, callerName: callerName, expiresAt: expiresAt, systemUUID: id)
    do { try await store.save(snapshot: record) }
    catch { provider.reportCall(with: id, endedAt: Date(), reason: .failed); throw error }
    scheduleRingDeadline(callId, at: expiresAt)
    return record
  }

  func startOutgoing(callId: String, calleeId: String, calleeName: String, media: String) async throws -> CallRecord {
    JackfieldLog.info("callkit.start_outgoing", callId: callId, detail: "media=\(media)")
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
    let update = CXCallUpdate()
    update.localizedCallerName = calleeName
    update.hasVideo = media == "video"
    Self.restrictUnsupportedActions(update)
    provider.reportCall(with: id, updated: update)
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
    Self.restrictUnsupportedActions(update)
    provider.reportCall(with: try await existingUUID(callId), updated: update)
    try await store.save(snapshot: record)
    return record
  }

  func setConnected(callId: String) async throws -> CallRecord {
    JackfieldLog.info("callkit.set_connected", callId: callId)
    guard var record = try await store.snapshot(callId: callId) else { throw JackfieldCoreError.invalidState }
    if record.state == "active" { return record }
    guard record.state == "connecting", record.actionId == nil else { throw JackfieldCoreError.invalidState }
    let id = try await existingUUID(callId)
    record.state = "active"
    try await store.save(snapshot: record)
    provider.reportOutgoingCall(with: id, connectedAt: Date())
    return record
  }

  func end(callId: String, reason: String) async throws -> CallRecord {
    JackfieldLog.info("callkit.end_requested", callId: callId, detail: "reason=\(reason)")
    guard let record = try await store.snapshot(callId: callId) else { throw JackfieldCoreError.invalidState }
    if record.state == "ended" { return record }
    ringDeadlines.removeValue(forKey: callId)?.cancel()
    let hadPendingAnswer = record.actionId.flatMap { pendingAnswers[$0] } != nil
    if let actionId = record.actionId, hadPendingAnswer {
      _ = try await complete(actionId: actionId, succeeded: false)
      return try await store.snapshot(callId: callId) ?? record
    }
    if (reason == "local" || reason == "rejected") && !hadPendingAnswer {
      let id = try await existingUUID(callId)
      requestedEndReasons[id] = reason
      try await request(CXTransaction(action: CXEndCallAction(call: id)))
      if let completed = try await store.snapshot(callId: callId), completed.state == "ended" { return completed }
    } else if !hadPendingAnswer, let id = record.systemUUID {
      let systemReason: CXCallEndedReason = reason == "remote" ? .remoteEnded : reason == "missed" ? .unanswered : .failed
      provider.reportCall(with: id, endedAt: Date(), reason: systemReason)
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
    JackfieldLog.info("callkit.answer_completed", callId: record.callId, detail: "succeeded=\(receipt.succeeded)")
    if receipt.succeeded {
      configureAudioSession()
      action.fulfill()
    }
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

  private func scheduleRingDeadline(_ callId: String, at deadline: Date) {
    ringDeadlines.removeValue(forKey: callId)?.cancel()
    ringDeadlines[callId] = Task { [weak self] in
      let delay = max(0, deadline.timeIntervalSinceNow + 0.001)
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self,
            let record = try? await self.store.snapshot(callId: callId), record.state == "ringing" else { return }
      _ = try? await self.end(callId: callId, reason: "missed")
    }
  }

  private func reconcileSystemCalls() async {
    guard let records = try? await store.allCallRecords() else { return }
    let observed = Set(callObserver.calls.filter { !$0.hasEnded }.map(\.uuid))
    for record in records where record.state != "ended" {
      if record.state == "ringing", let deadline = record.expiresAt {
        if deadline <= Date() {
          if let event = try? await store.saveEnded(callId: record.callId, eventId: UUID().uuidString, reason: "missed", at: Date()) { publish(event) }
          if let id = record.systemUUID, observed.contains(id) { provider.reportCall(with: id, endedAt: Date(), reason: .unanswered) }
          continue
        }
        scheduleRingDeadline(record.callId, at: deadline)
      }
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
    JackfieldLog.error("callkit.provider_reset")
    for (_, action) in pendingAnswers { action.fail() }
    for (_, timer) in answerDeadlines { timer.cancel() }
    for (_, timer) in ringDeadlines { timer.cancel() }
    pendingAnswers.removeAll(); answerDeadlines.removeAll(); ringDeadlines.removeAll()
    identifiers.removeAll(); callIds.removeAll(); requestedEndReasons.removeAll()
    Task { await reconcileSystemCalls() }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    JackfieldLog.info("callkit.outgoing_action")
    configureAudioSession()
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    JackfieldLog.info("callkit.audio_activated")
  }

  private func configureAudioSession() {
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      JackfieldLog.info("callkit.audio_configured", detail: "category=playAndRecord mode=voiceChat bluetooth=true")
    } catch {
      JackfieldLog.error("callkit.audio_configuration_failed", error: error)
    }
  }

  private static func restrictUnsupportedActions(_ update: CXCallUpdate) {
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    JackfieldLog.info("callkit.answer_action_received")
    Task {
      do {
        guard let callId = try await knownCallId(action.callUUID),
              let record = try await store.snapshot(callId: callId), record.state == "ringing" else { action.fail(); return }
        ringDeadlines.removeValue(forKey: callId)?.cancel()
        let deadline = min(action.timeoutDate, Date().addingTimeInterval(30))
        let actionId = UUID().uuidString
        let event = try await store.saveAnswerRequested(callId: callId, eventId: UUID().uuidString, actionId: actionId, deadline: deadline, at: Date())
        pendingAnswers[actionId] = action
        expireAnswer(actionId, deadline: deadline)
        publish(event)
        JackfieldLog.info("callkit.answer_requested", callId: callId)
      } catch {
        JackfieldLog.error("callkit.answer_action_failed", error: error)
        action.fail()
      }
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let requestedReason = requestedEndReasons.removeValue(forKey: action.callUUID)
    Task {
      do {
        guard let callId = try await knownCallId(action.callUUID),
              let record = try await store.snapshot(callId: callId) else { action.fail(); return }
        let reason = CallEndReasonPolicy.systemEnd(requested: requestedReason, state: record.state)
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
        JackfieldLog.info("callkit.end_action_completed", callId: callId, detail: "reason=\(reason)")
      } catch {
        JackfieldLog.error("callkit.end_action_failed", error: error)
        action.fail()
      }
    }
  }
}
