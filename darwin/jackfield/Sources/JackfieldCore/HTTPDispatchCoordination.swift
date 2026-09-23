import Foundation

public actor HTTPDispatchCoordination {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  internal var pendingAcquisitions: Int { waiters.count }

  public init() {}

  public func acquire() async {
    if !held { held = true; return }
    await withCheckedContinuation { waiters.append($0) }
  }

  public func release() {
    if waiters.isEmpty { held = false }
    else { waiters.removeFirst().resume() }
  }

  /// Only the final, synchronous enqueue runs under this coordination lock.
  /// Request construction, body file writes, and URLSession task creation must happen before this call.
  public func enqueueIfCurrent(store: EventStore, ticket: HTTPDispatchTicket,
                               clock: @Sendable () -> Date = { Date() },
                               enqueue: @Sendable () -> Void) async throws -> Bool {
    await acquire()
    do {
      let permitted = try await store.confirmHTTPDispatch(ticket, at: clock())
      if permitted { enqueue() }
      release()
      return permitted
    } catch {
      release()
      throw error
    }
  }
}
