import CryptoKit
import Foundation
import UserNotifications

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(macOS 11.0, *)
@MainActor
final class MacOSCallController: NSObject, UNUserNotificationCenterDelegate {
  private enum Category {
    static let incoming = "dev.albizia.jackfield.incoming"
    static let ongoing = "dev.albizia.jackfield.ongoing"
    static let answer = "dev.albizia.jackfield.answer"
    static let reject = "dev.albizia.jackfield.reject"
    static let end = "dev.albizia.jackfield.end"
  }

  private let center = UNUserNotificationCenter.current()
  private let store: EventStore
  private let flow: MacOSCallFlow
  private let publish: (WireEnvelope) -> Void
  private let reportFailure: (String) -> Void
  private var previousDelegate: UNUserNotificationCenterDelegate?
  private var deadlines: [String: Task<Void, Never>] = [:]

  init(store: EventStore, publish: @escaping (WireEnvelope) -> Void, reportFailure: @escaping (String) -> Void) {
    self.store = store
    self.flow = MacOSCallFlow(store: store)
    self.publish = publish
    self.reportFailure = reportFailure
    super.init()
    previousDelegate = center.delegate
    center.delegate = self
    Task { await ensureCategories() }
    Task { await restoreDeadlines() }
  }

  private func ensureCategories() async {
    let answer = UNNotificationAction(identifier: Category.answer, title: "Answer", options: [.foreground])
    let reject = UNNotificationAction(identifier: Category.reject, title: "Reject", options: [.destructive])
    let end = UNNotificationAction(identifier: Category.end, title: "End call", options: [.destructive])
    let existing = await withCheckedContinuation { (continuation: CheckedContinuation<Set<UNNotificationCategory>, Never>) in
      center.getNotificationCategories { categories in continuation.resume(returning: categories) }
    }
    let ours: Set<UNNotificationCategory> = [
      UNNotificationCategory(identifier: Category.incoming, actions: [answer, reject], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: Category.ongoing, actions: [end], intentIdentifiers: [], options: []),
    ]
    center.setNotificationCategories(existing.filter { $0.identifier != Category.incoming && $0.identifier != Category.ongoing }.union(ours))
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      center.getNotificationSettings { settings in continuation.resume(returning: settings.authorizationStatus) }
    }
  }

  private func requirePermission() async throws {
    let status = await authorizationStatus()
    guard status == .authorized || status == .provisional else { throw MacOSCallError.permissionDenied }
  }

  func reportIncoming(callId: String, callerId: String, callerName: String, media: String) async throws -> CallRecord {
    try await requirePermission()
    await ensureCategories()
    let record = try await flow.reportIncoming(callId: callId, callerId: callerId, callerName: callerName, media: media)
    guard record.state == "ringing" else { return record }
    do { try await present(record) }
    catch {
      let ended = try await flow.end(callId: callId, reason: "failed")
      if let event = ended.event { publish(event) }
      throw error
    }
    return record
  }

  func startOutgoing(callId: String, calleeId: String, calleeName: String, media: String) async throws -> CallRecord {
    try await requirePermission()
    await ensureCategories()
    let record = try await flow.startOutgoing(callId: callId, calleeId: calleeId, calleeName: calleeName, media: media)
    guard record.state == "connecting" else { return record }
    do { try await present(record) }
    catch {
      let ended = try await flow.end(callId: callId, reason: "failed")
      if let event = ended.event { publish(event) }
      throw error
    }
    return record
  }

  func update(callId: String, callerId: String?, callerName: String?, media: String?) async throws -> CallRecord {
    let record = try await flow.update(callId: callId, callerId: callerId, callerName: callerName, media: media)
    try await present(record)
    return record
  }

  func end(callId: String, reason: String) async throws -> CallRecord {
    let outcome = try await flow.end(callId: callId, reason: reason)
    removeNotification(callId)
    if let actionId = outcome.record.actionId { deadlines.removeValue(forKey: actionId)?.cancel() }
    if let event = outcome.event { publish(event) }
    return outcome.record
  }

  func complete(actionId: String, succeeded: Bool) async throws -> ActionReceipt {
    let outcome = try await flow.complete(actionId: actionId, succeeded: succeeded)
    deadlines.removeValue(forKey: actionId)?.cancel()
    if let event = outcome.ended { publish(event) }
    if let record = try await store.allCallRecords().first(where: { $0.actionId == actionId }) {
      if outcome.receipt.succeeded {
        do { try await present(record) }
        catch { reportFailure("platformFailure") }
      }
      else { removeNotification(record.callId) }
    }
    return outcome.receipt
  }

  private func present(_ record: CallRecord) async throws {
    let content = UNMutableNotificationContent()
    content.title = record.state == "ringing" ? "Incoming call" : "Call"
    content.body = record.callerName ?? "Unknown caller"
    content.categoryIdentifier = record.state == "ringing" ? Category.incoming : Category.ongoing
    content.userInfo = ["callId": record.callId]
    content.sound = .default
    let request = UNNotificationRequest(identifier: Self.notificationId(record.callId), content: content, trigger: nil)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      center.add(request) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func removeNotification(_ callId: String) {
    let id = Self.notificationId(callId)
    center.removePendingNotificationRequests(withIdentifiers: [id])
    center.removeDeliveredNotifications(withIdentifiers: [id])
  }

  private static func notificationId(_ callId: String) -> String {
    "dev.albizia.jackfield." + SHA256.hash(data: Data(callId.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func restoreDeadlines() async {
    guard let records = try? await store.allCallRecords() else { return }
    for record in records where record.state == "connecting" {
      if let actionId = record.actionId, let deadline = record.actionDeadline,
         !record.actionReceipts.contains(where: { $0.actionId == actionId }) {
        scheduleDeadline(actionId, at: deadline)
      }
    }
  }

  private func scheduleDeadline(_ actionId: String, at deadline: Date) {
    deadlines.removeValue(forKey: actionId)?.cancel()
    deadlines[actionId] = Task { [weak self] in
      let seconds = max(0, deadline.timeIntervalSinceNow + 0.001)
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do { _ = try await self.complete(actionId: actionId, succeeded: false) }
      catch { self.reportFailure("platformFailure") }
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    Task { @MainActor [weak self] in
      guard let self else { completionHandler(); return }
      await self.receive(center, response: response, completionHandler: completionHandler)
    }
  }

  private func receive(_ center: UNUserNotificationCenter, response: UNNotificationResponse,
                       completionHandler: @escaping @Sendable () -> Void) async {
    let action = response.actionIdentifier
    guard [Category.answer, Category.reject, Category.end].contains(action),
          let callId = response.notification.request.content.userInfo["callId"] as? String else {
      MacOSDelegateForwarding.forward(optionalCall: {
        previousDelegate?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
      }, fallback: completionHandler)
      return
    }
    defer { completionHandler() }
    if action == Category.answer {
      let actionId = UUID().uuidString
      let deadline = Date().addingTimeInterval(30)
      let outcome = await MacOSActionHandling.capture({
        try await flow.answer(callId: callId, actionId: actionId, eventId: UUID().uuidString, deadline: deadline)
      }, onFailure: reportFailure)
      switch outcome {
      case .success(let event):
        scheduleDeadline(actionId, at: deadline)
        publish(event)
        await restoreNotification(callId)
      case .failure:
        await restoreNotification(callId, preserveActionError: true)
      }
    } else {
      let outcome = await MacOSActionHandling.capture({
        try await end(callId: callId, reason: action == Category.reject ? "rejected" : "local")
      }, onFailure: reportFailure)
      if case .failure = outcome {
        await restoreNotification(callId, preserveActionError: true)
      }
    }
  }

  private func restoreNotification(_ callId: String, preserveActionError: Bool = false) async {
    do {
      if let record = try await store.snapshot(callId: callId), record.state != "ended" { try await present(record) }
    } catch {
      if !preserveActionError { reportFailure("platformFailure") }
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    Task { @MainActor [weak self] in
      guard let self else { completionHandler([]); return }
      self.presentForeground(center, notification: notification, completionHandler: completionHandler)
    }
  }

  private func presentForeground(_ center: UNUserNotificationCenter, notification: UNNotification,
                                 completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    if notification.request.identifier.hasPrefix("dev.albizia.jackfield.") {
      completionHandler([.banner, .sound])
    } else {
      MacOSDelegateForwarding.forward(optionalCall: {
        previousDelegate?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
      }, fallback: { completionHandler([]) })
    }
  }
}

enum MacOSCallError: Error { case permissionDenied }
