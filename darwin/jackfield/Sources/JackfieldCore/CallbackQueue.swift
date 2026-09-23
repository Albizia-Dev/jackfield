import Foundation

public struct HTTPConfiguration: Sendable, Equatable {
  public let endpoint: String
  public let ttl: TimeInterval
  public let limit: Int
  public init(endpoint: String, ttl: TimeInterval, limit: Int) {
    self.endpoint = endpoint; self.ttl = ttl; self.limit = limit
  }
}

public struct CallbackQueue: Sendable {
  private let store: EventStore
  public init(store: EventStore) { self.store = store }
  public func ready(at date: Date) async throws -> [WireEnvelope] { try await store.readyHTTP(at: date) }
  public func recordResponse(eventId: String, status: Int, at date: Date, retryAfter: TimeInterval? = nil) async throws {
    if (200...299).contains(status) { try await store.acknowledgeHTTP([eventId]); return }
    if status == 401 || status == 403 { try await store.pauseHTTPForAuthentication(); return }
    if status == 429 || (500...599).contains(status) {
      let priorAttempts = try await store.httpAttempts(eventId)
      let base = min(900, pow(2, Double(min(priorAttempts, 10))))
      let delay = min(900, (retryAfter ?? 0) > 0 ? retryAfter ?? base : base)
      try await store.scheduleHTTP(eventId, at: date.addingTimeInterval(delay)); return
    }
    try await store.markHTTPTerminal(eventId)
  }
}
