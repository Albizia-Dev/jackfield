import Foundation

/// Holds live events until a newly attached listener has received its durable replay.
public struct MacOSEventReplayBuffer {
  private var generation = 0
  private var replaying = false
  private var buffered: [WireEnvelope] = []
  private var delivered: Set<String> = []

  public init() {}

  public func isCurrent(_ expected: Int) -> Bool { generation == expected }

  public mutating func begin() -> Int {
    generation += 1
    replaying = true
    buffered.removeAll()
    delivered.removeAll()
    return generation
  }

  public mutating func cancel() {
    generation += 1
    replaying = false
    buffered.removeAll()
    delivered.removeAll()
  }

  public mutating func publish(_ event: WireEnvelope) -> [WireEnvelope] {
    if replaying { buffered.append(event); return [] }
    return delivered.insert(event.eventId).inserted ? [event] : []
  }

  public mutating func finish(generation expected: Int, pending: [WireEnvelope]) -> [WireEnvelope] {
    guard replaying, expected == generation else { return [] }
    let ordered = uniqueOrdered(pending + buffered)
    buffered.removeAll()
    return ordered
  }

  public mutating func drain(generation expected: Int) -> [WireEnvelope] {
    guard replaying, expected == generation else { return [] }
    if buffered.isEmpty { replaying = false; return [] }
    let ordered = uniqueOrdered(buffered)
    buffered.removeAll()
    return ordered
  }

  private mutating func uniqueOrdered(_ events: [WireEnvelope]) -> [WireEnvelope] {
    let ordered = events.sorted {
      if $0.callId != $1.callId { return $0.callId < $1.callId }
      if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
      return $0.eventId < $1.eventId
    }
    return ordered.filter { delivered.insert($0.eventId).inserted }
  }
}
