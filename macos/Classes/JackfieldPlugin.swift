import FlutterMacOS
import Foundation
import UserNotifications

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(macOS 11.0, *)
@MainActor
public final class JackfieldPlugin: NSObject, @preconcurrency FlutterPlugin {
  private let runtime = MacOSCallbackRuntime.shared
  private let store: EventStore?
  private var controller: MacOSCallController?
  private var eventsSink: FlutterEventSink?
  private var replayBuffer = MacOSEventReplayBuffer()
  private var lastError: String?

  private override init() {
    store = MacOSCallbackRuntime.shared.store
    super.init()
    if let store {
      controller = MacOSCallController(store: store, publish: { [weak self] event in self?.publish(event) },
                                       reportFailure: { [weak self] code in self?.lastError = code })
    }
    else { lastError = "platformFailure" }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = JackfieldPlugin()
    let channel = FlutterMethodChannel(name: "jackfield", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "jackfield/events", binaryMessenger: registrar.messenger).setStreamHandler(
      MacOSStreamHandler(onListen: { [weak instance] sink in
        instance?.startReplay(sink)
      }, onCancel: { [weak instance] in instance?.stopReplay() }))
    FlutterEventChannel(name: "jackfield/push_token_updates", binaryMessenger: registrar.messenger).setStreamHandler(
      MacOSStreamHandler(onListen: { _ in }, onCancel: {}))
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let data = call.arguments as? [String: Any], (data["version"] as? Int) == 1 else {
      result(Self.failure("protocolFailure")); return
    }
    Task { @MainActor in
      do {
        if self.store == nil || self.controller == nil {
          if call.method == "capabilities" {
            result(["version": 1, "platform": "macos", "mechanism": "unavailable", "features": [], "reason": "Native storage unavailable"])
            return
          }
          if call.method == "diagnostics" {
            result(["version": 1, "mechanism": "unavailable", "permissions": ["notifications": "unknown"],
                    "pendingFlutterEvents": NSNull(), "pendingHttpEvents": NSNull(),
                    "httpPausedForAuthentication": false, "lastError": ["code": "platformFailure"]] as [String: Any])
            return
          }
        }
        guard let store = self.store, let controller = self.controller else { throw JackfieldCoreError.platformFailure }
        switch call.method {
        case "initialize":
          try await self.configure(data)
          result(Self.success(NSNull()))
        case "capabilities":
          let capabilities = MacOSCapabilities.forNotificationAuthorization(Self.authorization(await controller.authorizationStatus()))
          var value: [String: Any] = ["version": 1, "platform": "macos", "mechanism": capabilities.mechanism,
                                      "features": capabilities.features]
          if let reason = capabilities.reason { value["reason"] = reason }
          result(value)
        case "diagnostics":
          let status = await controller.authorizationStatus()
          let capabilities = MacOSCapabilities.forNotificationAuthorization(Self.authorization(status))
          result(["version": 1, "mechanism": capabilities.mechanism,
                  "permissions": ["notifications": Self.permission(status)],
                  "pendingFlutterEvents": try await store.pendingFlutterCount(),
                  "pendingHttpEvents": try await store.pendingHTTPCount(),
                  "httpPausedForAuthentication": try await store.httpPausedForAuthentication(),
                  "lastError": self.lastError.map { ["code": $0] } ?? NSNull()] as [String: Any])
        case "reportIncomingCall":
          let (id, person, media) = try Self.callData(data, person: "caller")
          result(Self.success(try await controller.reportIncoming(callId: id, callerId: person.0, callerName: person.1, media: media).toWire()))
        case "startOutgoingCall":
          let (id, person, media) = try Self.callData(data, person: "callee")
          result(Self.success(try await controller.startOutgoing(callId: id, calleeId: person.0, calleeName: person.1, media: media).toWire()))
        case "updateCall":
          let id = try Self.nonempty(data["callId"])
          let person: (String, String)? = data["caller"] == nil ? nil : try Self.person(data["caller"])
          let media: String? = data["media"] == nil ? nil : try Self.media(data["media"])
          result(Self.success(try await controller.update(callId: id, callerId: person?.0, callerName: person?.1, media: media).toWire()))
        case "endCall":
          let id = try Self.nonempty(data["callId"])
          let reason = try Self.nonempty(data["reason"])
          guard ["local", "remote", "rejected", "missed", "failed"].contains(reason) else { throw JackfieldCoreError.protocolFailure }
          result(Self.success(try await controller.end(callId: id, reason: reason).toWire()))
        case "completeAction":
          let id = try Self.nonempty(data["actionId"])
          guard let succeeded = data["succeeded"] as? Bool else { throw JackfieldCoreError.protocolFailure }
          let receipt = try await controller.complete(actionId: id, succeeded: succeeded)
          result(receipt.errorCode == "deadlineExceeded" ? Self.failure("deadlineExceeded") : Self.success(NSNull()))
        case "acknowledgeEvents":
          guard let ids = data["eventIds"] as? [String],
                ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw JackfieldCoreError.protocolFailure }
          try await store.acknowledgeFlutter(Set(ids))
          result(Self.success(NSNull()))
        case "pushTokens":
          result(Self.success(["tokens": []]))
        default:
          result(Self.failure("unsupported"))
        }
      } catch {
        let code = Self.code(error)
        self.lastError = code
        if call.method == "capabilities" || call.method == "diagnostics" {
          result(FlutterError(code: code, message: nil, details: nil))
        } else { result(Self.failure(code)) }
      }
    }
  }

  private func configure(_ data: [String: Any]) async throws {
    if let raw = data["callbacks"] {
      guard let value = raw as? [String: Any], let endpoint = value["endpoint"] as? String,
            let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
            url.user == nil, url.password == nil, url.fragment == nil,
            let auth = value["auth"] as? [String: String], auth["type"] == "bearer",
            let token = auth["token"], !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !token.contains("\r"), !token.contains("\n"),
            let ttl = value["timeToLiveMs"] as? Int, ttl > 0,
            let limit = value["maxPendingEvents"] as? Int, limit > 0 else { throw JackfieldCoreError.protocolFailure }
      try await runtime.configure(endpoint: url, token: token, ttl: TimeInterval(ttl) / 1000, limit: limit)
    } else { try await runtime.disable() }
  }

  private func publish(_ event: WireEnvelope) {
    if let eventsSink {
      for ready in replayBuffer.publish(event) { eventsSink(ready.toWire()) }
    }
    Task { await runtime.sendReady() }
  }

  private func startReplay(_ sink: @escaping FlutterEventSink) {
    eventsSink = sink
    let generation = replayBuffer.begin()
    guard let store else {
      sink(FlutterError(code: "platformFailure", message: "Native storage unavailable", details: nil))
      return
    }
    Task { @MainActor [weak self] in
      let pending = try? await store.pendingFlutter()
      guard let self, self.replayBuffer.isCurrent(generation) else { return }
      if pending == nil {
        self.lastError = "platformFailure"
        self.eventsSink?(FlutterError(code: "platformFailure", message: nil, details: nil))
      }
      var batch = self.replayBuffer.finish(generation: generation, pending: pending ?? [])
      while self.replayBuffer.isCurrent(generation) {
        for event in batch {
          guard self.replayBuffer.isCurrent(generation) else { return }
          self.eventsSink?(event.toWire())
        }
        batch = self.replayBuffer.drain(generation: generation)
        if batch.isEmpty { return }
      }
    }
  }

  private func stopReplay() {
    replayBuffer.cancel()
    eventsSink = nil
  }

  private static func authorization(_ status: UNAuthorizationStatus) -> MacOSNotificationAuthorization {
    switch status {
    case .authorized: return .authorized
    case .provisional: return .provisional
    case .denied: return .denied
    default: return .notDetermined
    }
  }

  private static func permission(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional: return "granted"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    default: return "unknown"
    }
  }

  private static func success(_ value: Any) -> [String: Any] { ["version": 1, "status": "success", "value": value] }
  private static func failure(_ code: String) -> [String: Any] { ["version": 1, "status": "failure", "error": ["code": code]] }
  private static func code(_ error: Error) -> String {
    if let local = error as? MacOSCallError, case .permissionDenied = local { return "permissionDenied" }
    switch error as? JackfieldCoreError {
    case .protocolFailure: return "protocolFailure"
    case .storageFull: return "storageFull"
    case .invalidState: return "invalidState"
    case .deadlineExceeded: return "deadlineExceeded"
    case .temporarilyUnavailable: return "temporarilyUnavailable"
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

private final class MacOSStreamHandler: NSObject, FlutterStreamHandler {
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
