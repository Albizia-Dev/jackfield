import CryptoKit
import Foundation
import Security

#if canImport(JackfieldCore)
import JackfieldCore
#endif

@available(macOS 11.0, *)
@MainActor
final class MacOSCallbackRuntime {
  static let shared = MacOSCallbackRuntime()

  let store: EventStore?
  private let delegate = NoRedirectDelegate()
  private lazy var session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
  private var active: Set<String> = []
  private var wake: Task<Void, Never>?

  private init() {
    do {
      let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("jackfield", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      store = try EventStore(path: folder.appendingPathComponent("events.sqlite3").path)
    } catch { store = nil }
    Task { await sendReady() }
  }

  func configure(endpoint: URL, token: String, ttl: TimeInterval, limit: Int) async throws {
    guard let store else { throw JackfieldCoreError.platformFailure }
    try MacOSCredentialStore.save(token)
    let fingerprint = Self.fingerprint(endpoint: endpoint, token: token)
    try await store.configureHTTP(limit: limit, credentialFingerprint: fingerprint,
                                  endpoint: endpoint.absoluteString, ttl: ttl)
    try await store.resumeHTTPAfterCredentialRotation()
    await sendReady()
  }

  func disable() async throws {
    guard let store else { throw JackfieldCoreError.platformFailure }
    try await store.disableHTTP()
    MacOSCredentialStore.delete()
    wake?.cancel()
  }

  func sendReady() async {
    guard let store else { return }
    wake?.cancel()
    try? await store.expireHTTP(at: Date())
    if let config = try? await store.httpConfiguration(),
       let endpoint = URL(string: config.endpoint),
       let token = MacOSCredentialStore.read(),
       let events = try? await CallbackQueue(store: store).ready(at: Date()) {
      let fingerprint = Self.fingerprint(endpoint: endpoint, token: token)
      for event in events where active.insert(event.eventId).inserted {
        Task { await deliver(event, to: endpoint, token: token, fingerprint: fingerprint) }
      }
    }
    guard let next = try? await store.nextHTTPWake() else { return }
    let delay = max(1, next.timeIntervalSinceNow)
    wake = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.sendReady()
    }
  }

  private func deliver(_ event: WireEnvelope, to endpoint: URL, token: String, fingerprint: String) async {
    defer {
      active.remove(event.eventId)
      Task { await sendReady() }
    }
    guard let store else { return }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(event.eventId, forHTTPHeaderField: "Idempotency-Key")
    guard let body = try? JSONSerialization.data(withJSONObject: ["version": 1, "event": event.toWire()]) else { return }
    request.httpBody = body
    let (status, retryAfter) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, TimeInterval?), Never>) in
      session.dataTask(with: request) { _, response, error in
        let http = response as? HTTPURLResponse
        let status = error == nil ? (http?.statusCode ?? 503) : 503
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        continuation.resume(returning: (status, retryAfter))
      }.resume()
    }
    try? await CallbackQueue(store: store).recordResponse(eventId: event.eventId, status: status,
      credentialFingerprint: fingerprint, at: Date(), retryAfter: retryAfter)
  }

  private static func fingerprint(endpoint: URL, token: String) -> String {
    SHA256.hash(data: Data((endpoint.absoluteString + "\u{0}" + token).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

private enum MacOSCredentialStore {
  private static let account = "jackfield.callback.bearer"
  private static let service = "dev.albizia.jackfield.macos"

  static func save(_ token: String) throws {
    let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
    let update = [kSecValueData: Data(token.utf8)] as CFDictionary
    let status = SecItemUpdate(query, update)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw JackfieldCoreError.platformFailure }
    let add = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                          kSecAttrAccount: account, kSecValueData: Data(token.utf8)] as CFDictionary, nil)
    guard add == errSecSuccess else { throw JackfieldCoreError.platformFailure }
  }

  static func read() -> String? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func delete() {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
  }
}
