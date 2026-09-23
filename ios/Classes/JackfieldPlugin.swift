import Flutter
import Foundation
import CryptoKit
import Security
import UIKit

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
public final class JackfieldPlugin: NSObject, FlutterPlugin {
  private let store: EventStore?
  private var controller: IOSCallController?
  private var registry: JackfieldPushRegistry?
  private var callback: JackfieldHTTPDispatcher?
  private var eventsSink: FlutterEventSink?
  private var tokensSink: FlutterEventSink?
  private var pushToken: String?
  private var lastError: String?

  private override init() {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jackfield", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    store = try? EventStore(path: folder.appendingPathComponent("events.sqlite3").path)
    super.init()
    if let store {
      controller = IOSCallController(store: store) { [weak self] event in self?.publish(event) }
      Task { [weak self] in
        guard let self, let config = try? await store.httpConfiguration(),
              let endpoint = URL(string: config.endpoint), JackfieldCredentialStore.read() != nil else { return }
        self.callback = JackfieldHTTPDispatcher(store: store, endpoint: endpoint, ttl: config.ttl, limit: config.limit)
        await self.callback?.sendReady()
      }
    }
    startPushRegistry()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = JackfieldPlugin()
    let channel = FlutterMethodChannel(name: "jackfield", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "jackfield/events", binaryMessenger: registrar.messenger()).setStreamHandler(JackfieldStreamHandler(onListen: { [weak instance] sink in
      instance?.eventsSink = sink
      instance?.replay()
    }, onCancel: { [weak instance] in instance?.eventsSink = nil }))
    FlutterEventChannel(name: "jackfield/push_token_updates", binaryMessenger: registrar.messenger()).setStreamHandler(JackfieldStreamHandler(onListen: { [weak instance] sink in
      instance?.tokensSink = sink
    }, onCancel: { [weak instance] in instance?.tokensSink = nil }))
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let data = call.arguments as? [String: Any], (data["version"] as? Int) == 1 else { result(Self.failure("protocolFailure")); return }
    Task { @MainActor in
      do {
        guard let store = self.store else { throw JackfieldCoreError.platformFailure }
        switch call.method {
        case "initialize":
          try await self.configure(data)
          result(Self.success(NSNull()))
        case "capabilities":
          result(self.capabilities())
        case "diagnostics":
          result(try await self.diagnostics(store))
        case "reportIncomingCall":
          let (id, person, media) = try Self.callData(data, person: "caller")
          guard let controller = self.controller else { throw JackfieldCoreError.platformFailure }
          result(Self.success(try await controller.reportIncoming(callId: id, callerId: person.0, callerName: person.1, media: media).toWire()))
        case "startOutgoingCall":
          let (id, person, media) = try Self.callData(data, person: "callee")
          guard let controller = self.controller else { throw JackfieldCoreError.platformFailure }
          result(Self.success(try await controller.startOutgoing(callId: id, calleeId: person.0, calleeName: person.1, media: media).toWire()))
        case "updateCall":
          let id = try Self.nonempty(data["callId"])
          let person: (String, String)? = data["caller"] == nil ? nil : try Self.person(data["caller"])
          let media: String? = data["media"] == nil ? nil : try Self.media(data["media"])
          guard let controller = self.controller else { throw JackfieldCoreError.platformFailure }
          result(Self.success(try await controller.update(callId: id, callerId: person?.0, callerName: person?.1, media: media).toWire()))
        case "endCall":
          let id = try Self.nonempty(data["callId"])
          let reason = try Self.nonempty(data["reason"])
          guard ["local", "remote", "rejected", "missed", "failed"].contains(reason) else { throw JackfieldCoreError.protocolFailure }
          guard let controller = self.controller else { throw JackfieldCoreError.platformFailure }
          result(Self.success(try await controller.end(callId: id, reason: reason).toWire()))
        case "completeAction":
          let id = try Self.nonempty(data["actionId"])
          guard let succeeded = data["succeeded"] as? Bool else { throw JackfieldCoreError.protocolFailure }
          guard let controller = self.controller else { throw JackfieldCoreError.platformFailure }
          let receipt = try await controller.complete(actionId: id, succeeded: succeeded)
          if receipt.errorCode == "deadlineExceeded" { result(Self.failure("deadlineExceeded")) }
          else { result(Self.success(NSNull())) }
        case "acknowledgeEvents":
          guard let ids = data["eventIds"] as? [String], ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw JackfieldCoreError.protocolFailure }
          try await store.acknowledgeFlutter(Set(ids))
          result(Self.success(NSNull()))
        case "pushTokens":
          result(Self.success(["tokens": self.pushToken.map { [["provider": "apns", "value": $0]] } ?? []]))
        default: result(Self.failure("unsupported"))
        }
      } catch {
        let code = Self.code(error)
        self.lastError = code
        if call.method == "capabilities" || call.method == "diagnostics" { result(FlutterError(code: code, message: nil, details: nil)) }
        else { result(Self.failure(code)) }
      }
    }
  }

  private func configure(_ data: [String: Any]) async throws {
    if let raw = data["callbacks"] {
      guard let value = raw as? [String: Any], let endpoint = value["endpoint"] as? String,
            let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
            let auth = value["auth"] as? [String: String], auth["type"] == "bearer", let token = auth["token"],
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !token.contains("\r"), !token.contains("\n"),
            let ttl = value["timeToLiveMs"] as? Int, ttl > 0,
            let limit = value["maxPendingEvents"] as? Int, limit > 0 else { throw JackfieldCoreError.protocolFailure }
      if let store {
        let fingerprint = SHA256.hash(data: Data((endpoint + "\u{0}" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        try await store.configureHTTP(limit: limit, credentialFingerprint: fingerprint, endpoint: endpoint, ttl: TimeInterval(ttl) / 1000)
        try JackfieldCredentialStore.save(token)
        callback = JackfieldHTTPDispatcher(store: store, endpoint: url, ttl: TimeInterval(ttl) / 1000, limit: limit)
        try await store.resumeHTTPAfterCredentialRotation()
        Task { await callback?.sendReady() }
      }
    } else {
      if let store { try await store.disableHTTP() }
      callback = nil
      JackfieldCredentialStore.delete()
    }
  }

  private func startPushRegistry() {
    registry = JackfieldPushRegistry(incoming: { [weak self] callId, callerId, callerName, media, completion in
      guard let self, let controller = self.controller else { completion(); return }
      Task { _ = try? await controller.reportIncoming(callId: callId, callerId: callerId, callerName: callerName, media: media); completion() }
    }, tokenChanged: { [weak self] value, removed in
      guard let self else { return }
      let prior = self.pushToken
      self.pushToken = value
      if let token = value ?? prior { self.tokensSink?(["version": 1, "token": ["provider": "apns", "value": token], "removed": removed]) }
    })
  }

  private func publish(_ event: WireEnvelope) {
    DispatchQueue.main.async { [weak self] in
      self?.eventsSink?(event.toWire())
      Task { await self?.callback?.sendReady() }
    }
  }
  private func replay() {
    guard let store else { return }
    Task { [weak self] in
      guard let self else { return }
      guard let pending = try? await store.pendingFlutter() else { return }
      for event in pending { await MainActor.run { self.eventsSink?(event.toWire()) } }
    }
  }
  private func capabilities() -> [String: Any] {
    guard store != nil, controller != nil else { return ["version": 1, "platform": "ios", "mechanism": "unavailable", "features": [], "reason": "Native storage unavailable"] }
    return ["version": 1, "platform": "ios", "mechanism": "nativeCallUi", "features": ["incoming", "outgoing", "answer", "end", "durableEvents", "httpCallbacks", "pushTokens"]]
  }
  private func diagnostics(_ store: EventStore) async throws -> [String: Any] {
    ["version": 1, "mechanism": "nativeCallUi", "permissions": ["voipPush": "unknown"],
     "pendingFlutterEvents": try await store.pendingFlutterCount(), "pendingHttpEvents": try await store.pendingHTTPCount(),
     "httpPausedForAuthentication": try await store.httpPausedForAuthentication(),
     "lastError": lastError.map { ["code": $0] } ?? NSNull()] as [String: Any]
  }
  private static func success(_ value: Any) -> [String: Any] { ["version": 1, "status": "success", "value": value] }
  private static func failure(_ code: String) -> [String: Any] { ["version": 1, "status": "failure", "error": ["code": code]] }
  private static func code(_ error: Error) -> String {
    switch error as? JackfieldCoreError {
    case .protocolFailure: return "protocolFailure"
    case .storageFull: return "storageFull"
    case .invalidState: return "invalidState"
    case .deadlineExceeded: return "deadlineExceeded"
    default: return "platformFailure"
    }
  }
  private static func nonempty(_ value: Any?) throws -> String {
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JackfieldCoreError.protocolFailure }
    return text
  }
  private static func media(_ value: Any?) throws -> String {
    let text = try nonempty(value)
    guard ["audio", "video"].contains(text) else { throw JackfieldCoreError.protocolFailure }
    return text
  }
  private static func person(_ value: Any?) throws -> (String, String) {
    guard let map = value as? [String: Any] else { throw JackfieldCoreError.protocolFailure }
    return (try nonempty(map["id"]), try nonempty(map["displayName"]))
  }
  private static func callData(_ data: [String: Any], person key: String) throws -> (String, (String, String), String) {
    (try nonempty(data["callId"]), try person(data[key]), try media(data["media"]))
  }
}

private final class JackfieldStreamHandler: NSObject, FlutterStreamHandler {
  private let onListenBlock: (@escaping FlutterEventSink) -> Void
  private let onCancelBlock: () -> Void
  init(onListen: @escaping (@escaping FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
    onListenBlock = onListen; onCancelBlock = onCancel
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard let map = arguments as? [String: Int], map == ["version": 1] else { return FlutterError(code: "protocolFailure", message: nil, details: nil) }
    onListenBlock(events); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { onCancelBlock(); return nil }
}

private enum JackfieldCredentialStore {
  private static let account = "jackfield.callback.bearer"
  static func save(_ token: String) throws {
    delete()
    let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecValueData: Data(token.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    guard status == errSecSuccess else { throw JackfieldCoreError.platformFailure }
  }
  static func read() -> String? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func delete() { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary) }
}

@available(iOS 13.0, *)
private final class JackfieldHTTPDispatcher: NSObject, URLSessionTaskDelegate {
  private let store: EventStore
  private let endpoint: URL
  private let ttl: TimeInterval
  private let limit: Int
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: (Bundle.main.bundleIdentifier ?? "jackfield") + ".jackfield.callbacks")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  init(store: EventStore, endpoint: URL, ttl: TimeInterval, limit: Int) {
    self.store = store; self.endpoint = endpoint; self.ttl = ttl; self.limit = limit
  }
  func sendReady() async {
    guard let token = JackfieldCredentialStore.read(), let ready = try? await store.readyHTTP(at: Date()) else { return }
    let active = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
      session.getAllTasks { tasks in continuation.resume(returning: Set(tasks.compactMap(\.taskDescription))) }
    }
    for event in ready {
      if active.contains(event.eventId) { continue }
      if Date().timeIntervalSince(event.occurredAt) >= ttl { try? await store.markHTTPTerminal(event.eventId); continue }
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue(event.eventId, forHTTPHeaderField: "Idempotency-Key")
      guard let body = try? JSONSerialization.data(withJSONObject: ["version": 1, "event": event.toWire()]) else { continue }
      let digest = SHA256.hash(data: Data(event.eventId.utf8)).map { String(format: "%02x", $0) }.joined()
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("jackfield-\(digest).json")
      do { try body.write(to: file, options: .atomic) } catch { continue }
      let task = session.uploadTask(with: request, fromFile: file)
      task.taskDescription = event.eventId
      task.resume()
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = task.taskDescription else { return }
    let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("jackfield-\(digest).json"))
    Task {
      let status = (task.response as? HTTPURLResponse)?.statusCode ?? 503
      let retryAfter = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
      try? await CallbackQueue(store: store).recordResponse(eventId: id, status: error == nil ? status : 503, at: Date(), retryAfter: retryAfter)
      if error != nil || status == 429 || (500...599).contains(status) {
        let attempts = (try? await store.httpAttempts(id)) ?? 1
        let base = pow(2, Double(min(max(0, attempts - 1), 10)))
        let delay = min(900, (retryAfter ?? 0) > 0 ? retryAfter ?? base : base)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await sendReady()
      }
    }
  }
}
