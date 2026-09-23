import Flutter
import Foundation
import UIKit

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(iOS 13.0, *)
public final class JackfieldPlugin: NSObject, FlutterPlugin {
  private static let backgroundRuntime = JackfieldBackgroundRuntime.shared
  private let store: EventStore?
  private var controller: IOSCallController?
  private var registry: JackfieldPushRegistry?
  private lazy var replaySession = DarwinEventReplaySession(loadPending: { [weak self] in
    guard let store = self?.store else { throw JackfieldCoreError.platformFailure }
    return try await store.pendingFlutter()
  })
  private var tokensSink: FlutterEventSink?
  private var pushToken: String?
  private var diagnosticError = DiagnosticErrorState()

  private override init() {
    store = Self.backgroundRuntime.store
    super.init()
    if let store {
      controller = IOSCallController(store: store) { [weak self] event in self?.publish(event) }
      startPushRegistry()
    } else {
      diagnosticError.record("platformFailure")
    }
  }

  public static func registerBackgroundProcessing() {
    backgroundRuntime.registerBackgroundProcessing()
  }

  public static func resumeCallbackDelivery() {
    Task { await backgroundRuntime.sendReady() }
  }

  @discardableResult
  public static func handleBackgroundURLSessionEvents(_ identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    backgroundRuntime.handleBackgroundEvents(identifier, completionHandler: completionHandler)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = JackfieldPlugin()
    let channel = FlutterMethodChannel(name: "jackfield", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "jackfield/events", binaryMessenger: registrar.messenger()).setStreamHandler(JackfieldStreamHandler(onListen: { [weak instance] sink in
      instance?.startReplay(sink)
    }, onCancel: { [weak instance] in instance?.replaySession.cancel() }))
    FlutterEventChannel(name: "jackfield/push_token_updates", binaryMessenger: registrar.messenger()).setStreamHandler(JackfieldStreamHandler(onListen: { [weak instance] sink in
      instance?.tokensSink = sink
    }, onCancel: { [weak instance] in instance?.tokensSink = nil }))
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let data = call.arguments as? [String: Any], (data["version"] as? Int) == 1 else { result(Self.failure("protocolFailure")); return }
    Task { @MainActor in
      do {
        guard let store = self.store else { throw Self.backgroundRuntime.storageFailure ?? JackfieldCoreError.platformFailure }
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
          if !ids.isEmpty { self.diagnosticError.acknowledgeFlutter() }
          result(Self.success(NSNull()))
        case "pushTokens":
          result(Self.success(["tokens": self.pushToken.map { [["provider": "apns", "value": $0]] } ?? []]))
        default: result(Self.failure("unsupported"))
        }
      } catch {
        let code = Self.code(error)
        self.diagnosticError.record(code)
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
      try await Self.backgroundRuntime.configure(endpoint: url, token: token, ttl: TimeInterval(ttl) / 1000, limit: limit)
    } else {
      try await Self.backgroundRuntime.disableCallbacks()
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
      self?.replaySession.publish(event)
      Task { await Self.backgroundRuntime.sendReady() }
    }
  }
  private func startReplay(_ sink: @escaping FlutterEventSink) {
    replaySession.start(onEvent: { sink($0.toWire()) }, onFailure: { [weak self] in
      self?.diagnosticError.record("platformFailure")
      sink(FlutterError(code: "platformFailure", message: "Durable event replay unavailable", details: nil))
      sink(FlutterEndOfEventStream)
    })
  }
  private func capabilities() -> [String: Any] {
    guard store != nil, controller != nil else { return ["version": 1, "platform": "ios", "mechanism": "unavailable", "features": [], "reason": "Native storage unavailable"] }
    return ["version": 1, "platform": "ios", "mechanism": "nativeCallUi", "features": ["incoming", "outgoing", "answer", "end", "durableEvents", "httpCallbacks", "pushTokens"]]
  }
  private func diagnostics(_ store: EventStore) async throws -> [String: Any] {
    let dropped = try await store.httpCapacityDroppedCount()
    let error = diagnosticError.visibleError(activeCapacityDrops: dropped)
    return ["version": 1, "mechanism": "nativeCallUi", "permissions": ["voipPush": "unknown"],
     "pendingFlutterEvents": try await store.pendingFlutterCount(), "pendingHttpEvents": try await store.pendingHTTPCount(),
     "httpPausedForAuthentication": try await store.httpPausedForAuthentication(),
     "lastError": error.map { ["code": $0] } ?? NSNull()] as [String: Any]
  }
  private static func success(_ value: Any) -> [String: Any] { ["version": 1, "status": "success", "value": value] }
  private static func failure(_ code: String) -> [String: Any] { ["version": 1, "status": "failure", "error": ["code": code]] }
  private static func code(_ error: Error) -> String {
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
