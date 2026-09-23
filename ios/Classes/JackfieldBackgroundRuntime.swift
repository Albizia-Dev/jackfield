import BackgroundTasks
import CryptoKit
import Foundation
import Security
import UIKit

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
final class JackfieldBackgroundRuntime {
  static let shared = JackfieldBackgroundRuntime()
  static let refreshIdentifier = "dev.albizia.jackfield.callbackRefresh"
  static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "jackfield") + ".jackfield.callbacks"

  let store: EventStore?
  let storageFailure: JackfieldCoreError?
  private let dispatcher: JackfieldHTTPDispatcher?
  private var registered = false

  private init() {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("jackfield", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    do {
      store = try EventStore(path: folder.appendingPathComponent("events.sqlite3").path)
      storageFailure = nil
    } catch {
      store = nil
      storageFailure = .platformFailure
    }
    if let store {
      dispatcher = JackfieldHTTPDispatcher(store: store)
    } else { dispatcher = nil }
  }

  func configure(endpoint: URL, token: String, ttl: TimeInterval, limit: Int) async throws {
    guard let store else { throw JackfieldCoreError.platformFailure }
    let fingerprint = Self.fingerprint(endpoint: endpoint, token: token)
    try await store.configureHTTP(limit: limit, credentialFingerprint: fingerprint,
                                  endpoint: endpoint.absoluteString, ttl: ttl)
    try JackfieldCredentialStore.save(token)
    try await store.resumeHTTPAfterCredentialRotation()
    await sendReady()
  }

  func disableCallbacks() async throws {
    guard let store else { throw JackfieldCoreError.platformFailure }
    try await store.disableHTTP()
    JackfieldCredentialStore.delete()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
  }

  func sendReady() async {
    await dispatcher?.sendReady()
    await scheduleRefresh()
  }

  func handleBackgroundEvents(_ identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    guard identifier == Self.sessionIdentifier, let dispatcher else { return false }
    dispatcher.handleBackgroundEvents(completionHandler)
    return true
  }

  func registerBackgroundProcessing() {
    guard store != nil else { return }
    guard !registered else { return }
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { [weak self] task in
      guard let self else { task.setTaskCompleted(success: false); return }
      let finish = JackfieldTaskCompletion(task: task)
      let work = Task {
        await self.sendReady()
        finish.complete(success: !Task.isCancelled)
      }
      task.expirationHandler = { work.cancel(); finish.complete(success: false) }
    }
    Task { await sendReady() }
  }

  private func scheduleRefresh() async {
    guard registered, let store else { return }
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
    guard let due = try? await store.nextHTTPWake() else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
    request.earliestBeginDate = max(due, Date().addingTimeInterval(60))
    try? BGTaskScheduler.shared.submit(request)
  }

  static func fingerprint(endpoint: URL, token: String) -> String {
    SHA256.hash(data: Data((endpoint.absoluteString + "\u{0}" + token).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

@available(iOS 13.0, *)
private final class JackfieldTaskCompletion {
  private let task: BGTask
  private let lock = NSLock()
  private var finished = false
  init(task: BGTask) { self.task = task }
  func complete(success: Bool) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    lock.unlock()
    task.setTaskCompleted(success: success)
  }
}

private enum JackfieldCredentialStore {
  private static let account = "jackfield.callback.bearer"
  static func save(_ token: String) throws {
    let query = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary
    let update = [kSecValueData: Data(token.utf8)] as CFDictionary
    let status = SecItemUpdate(query, update)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw JackfieldCoreError.platformFailure }
    let add = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account,
                          kSecValueData: Data(token.utf8),
                          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    guard add == errSecSuccess else { throw JackfieldCoreError.platformFailure }
  }
  static func read() -> String? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func delete() {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary)
  }
}

@available(iOS 13.0, *)
private struct JackfieldTaskMetadata: Codable {
  let eventId: String
  let credentialFingerprint: String
  let attemptId: UUID?

  var description: String? { try? JSONEncoder().encode(self).base64EncodedString() }
  init?(description: String?) {
    guard let description, let data = Data(base64Encoded: description),
          let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
    self = value
  }
  init(eventId: String, credentialFingerprint: String, attemptId: UUID? = nil) {
    self.eventId = eventId; self.credentialFingerprint = credentialFingerprint; self.attemptId = attemptId
  }
  static func from(_ task: URLSessionTask) -> Self? {
    if let persisted = Self(description: task.taskDescription) { return persisted }
    guard let request = task.originalRequest,
          let endpoint = request.url,
          let eventId = request.value(forHTTPHeaderField: "Idempotency-Key"),
          let authorization = request.value(forHTTPHeaderField: "Authorization"),
          authorization.hasPrefix("Bearer ") else { return nil }
    let token = String(authorization.dropFirst("Bearer ".count))
    return Self(eventId: eventId, credentialFingerprint: JackfieldBackgroundRuntime.fingerprint(endpoint: endpoint, token: token))
  }
}

@available(iOS 13.0, *)
private final class JackfieldHTTPDispatcher: NSObject, URLSessionTaskDelegate {
  private let store: EventStore
  // Serializes only dispatcher scans; EventStore/configuration never acquires this gate.
  private let scanGate = HTTPDispatchCoordination()
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: JackfieldBackgroundRuntime.sessionIdentifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  private let eventQueue = DispatchQueue(label: "dev.albizia.jackfield.urlsession-events")
  private let ignoredTaskLock = NSLock()
  private var ignoredTaskIdentifiers: Set<Int> = []
  private var pendingProcessing = 0
  private var didFinishEvents = false
  private var backgroundCompletion: (() -> Void)?

  init(store: EventStore) { self.store = store }

  func handleBackgroundEvents(_ completionHandler: @escaping () -> Void) {
    eventQueue.sync {
      self.backgroundCompletion = completionHandler
      self.didFinishEvents = false
    }
    _ = session
  }

  func sendReady() async {
    await scanGate.acquire()
    await sendReadySerial()
    await scanGate.release()
  }

  private func sendReadySerial() async {
    try? await store.expireHTTP(at: Date())
    guard let ready = try? await store.readyHTTP(at: Date()) else { return }
    let active = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
      session.getAllTasks { tasks in
        let ids = tasks.compactMap { task -> String? in
          if task.state == .suspended {
            // A crash between uploadTask and resume leaves an unsent task in the background session.
            self.ignoreCompletion(for: task)
            task.cancel()
            return nil
          }
          return JackfieldTaskMetadata.from(task)?.eventId
        }
        continuation.resume(returning: Set(ids))
      }
    }
    for event in ready {
      if active.contains(event.eventId) { continue }
      guard let ticket = try? await store.prepareHTTPDispatch(eventId: event.eventId, at: Date()),
            let token = JackfieldCredentialStore.read(),
            let endpoint = URL(string: ticket.configuration.endpoint),
            JackfieldBackgroundRuntime.fingerprint(endpoint: endpoint, token: token) == ticket.credentialFingerprint,
            var request = try? ticket.event.callbackRequest(to: endpoint, token: token),
            let body = request.httpBody else { continue }
      let attemptId = UUID()
      let file = Self.bodyFile(for: ticket.event.eventId, attemptId: attemptId)
      do { try body.write(to: file, options: .atomic) } catch { continue }
      request.httpBody = nil
      let task = session.uploadTask(with: request, fromFile: file)
      task.taskDescription = JackfieldTaskMetadata(eventId: ticket.event.eventId,
                                                    credentialFingerprint: ticket.credentialFingerprint,
                                                    attemptId: attemptId).description
      let coordination = store.dispatchCoordination
      let permitted = (try? await coordination.enqueueIfCurrent(store: store, ticket: ticket) {
        // Only synchronous enqueue runs under coordination; all file and task work ran outside it.
        task.resume()
      }) ?? false
      if !permitted {
        ignoreCompletion(for: task)
        task.cancel()
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  private static func bodyFile(for eventId: String, attemptId: UUID? = nil) -> URL {
    let digest = SHA256.hash(data: Data(eventId.utf8)).map { String(format: "%02x", $0) }.joined()
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("jackfield/uploads", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let suffix = attemptId.map { "-\($0.uuidString)" } ?? ""
    return folder.appendingPathComponent("jackfield-\(digest)\(suffix).json")
  }

  private func ignoreCompletion(for task: URLSessionTask) {
    ignoredTaskLock.lock(); defer { ignoredTaskLock.unlock() }
    ignoredTaskIdentifiers.insert(task.taskIdentifier)
  }

  private func takeIgnoredCompletion(for task: URLSessionTask) -> Bool {
    ignoredTaskLock.lock(); defer { ignoredTaskLock.unlock() }
    return ignoredTaskIdentifiers.remove(task.taskIdentifier) != nil
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if takeIgnoredCompletion(for: task) {
      if let metadata = JackfieldTaskMetadata.from(task) {
        try? FileManager.default.removeItem(at: Self.bodyFile(for: metadata.eventId, attemptId: metadata.attemptId))
      }
      return
    }
    guard let metadata = JackfieldTaskMetadata.from(task) else { return }
    eventQueue.async { self.pendingProcessing += 1 }
    Task {
      let status = (task.response as? HTTPURLResponse)?.statusCode ?? 503
      let retryAfter = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
      try? await CallbackQueue(store: store).recordResponse(eventId: metadata.eventId,
                 status: error == nil ? status : 503, credentialFingerprint: metadata.credentialFingerprint,
                 at: Date(), retryAfter: retryAfter)
      try? FileManager.default.removeItem(at: Self.bodyFile(for: metadata.eventId, attemptId: metadata.attemptId))
      await JackfieldBackgroundRuntime.shared.sendReady()
      eventQueue.async {
        self.pendingProcessing -= 1
        self.finishBackgroundEventsIfDrained()
      }
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    eventQueue.async {
      self.didFinishEvents = true
      self.finishBackgroundEventsIfDrained()
    }
  }

  private func finishBackgroundEventsIfDrained() {
    guard didFinishEvents, pendingProcessing == 0, let completion = backgroundCompletion else { return }
    backgroundCompletion = nil
    didFinishEvents = false
    DispatchQueue.main.async(execute: completion)
  }
}
