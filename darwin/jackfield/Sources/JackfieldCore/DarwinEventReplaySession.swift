import Foundation

/// Serializes a Flutter listener's durable replay with live native events.
/// All entry points and callbacks run on the main queue, as Flutter event channels do.
public final class DarwinEventReplaySession {
  private let loadPending: () async throws -> [WireEnvelope]
  private var buffer = MacOSEventReplayBuffer()
  private var onEvent: ((WireEnvelope) -> Void)?
  private var onFailure: (() -> Void)?

  public init(loadPending: @escaping () async throws -> [WireEnvelope]) {
    self.loadPending = loadPending
  }

  public func start(onEvent: @escaping (WireEnvelope) -> Void, onFailure: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.onEvent = onEvent
    self.onFailure = onFailure
    let generation = buffer.begin()
    let loadPending = self.loadPending
    Task { @MainActor [weak self] in
      do {
        let pending = try await loadPending()
        self?.finish(generation: generation, pending: pending)
      } catch {
        self?.fail(generation: generation)
      }
    }
  }

  public func publish(_ event: WireEnvelope) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let onEvent else { return }
    for ready in buffer.publish(event) { onEvent(ready) }
  }

  public func cancel() {
    dispatchPrecondition(condition: .onQueue(.main))
    buffer.cancel()
    onEvent = nil
    onFailure = nil
  }

  private func finish(generation: Int, pending: [WireEnvelope]) {
    guard buffer.isCurrent(generation) else { return }
    var batch = buffer.finish(generation: generation, pending: pending)
    while buffer.isCurrent(generation) {
      for event in batch {
        guard buffer.isCurrent(generation) else { return }
        onEvent?(event)
      }
      batch = buffer.drain(generation: generation)
      if batch.isEmpty { return }
    }
  }

  private func fail(generation: Int) {
    guard buffer.fail(generation: generation) else { return }
    let failure = onFailure
    onEvent = nil
    onFailure = nil
    failure?()
  }
}
