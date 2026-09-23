import Foundation

public enum MacOSActionOutcome<Value> {
  case success(Value)
  case failure(String)
}

/// Converts persistence failures into a safe, explicit notification-action outcome.
public enum MacOSActionHandling {
  public static func capture<Value>(_ operation: () async throws -> Value,
                                    onFailure: (String) -> Void) async -> MacOSActionOutcome<Value> {
    do { return .success(try await operation()) }
    catch {
      let safeCode = code(error)
      onFailure(safeCode)
      return .failure(safeCode)
    }
  }

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
}
