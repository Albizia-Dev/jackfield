public struct DiagnosticErrorState {
  private var lastError: String?

  public init() {}

  public mutating func record(_ code: String) { lastError = code }

  public mutating func reconcileCapacity(isAtCapacity: Bool) {
    if !isAtCapacity && lastError == "storageFull" { lastError = nil }
  }

  public func visibleError(activeCapacityDrops: Int) -> String? {
    lastError ?? (activeCapacityDrops > 0 ? "storageFull" : nil)
  }
}
