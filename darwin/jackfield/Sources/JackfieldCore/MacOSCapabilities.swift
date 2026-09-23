import Foundation

public enum MacOSNotificationAuthorization: Sendable {
  case authorized, provisional, denied, notDetermined
}

public struct MacOSCapabilities: Sendable {
  public let mechanism: String
  public let features: [String]
  public let reason: String?

  public static func forNotificationAuthorization(_ status: MacOSNotificationAuthorization) -> Self {
    switch status {
    case .authorized, .provisional:
      return Self(mechanism: "systemNotification",
                  features: ["incoming", "outgoing", "answer", "reject", "end", "durableEvents", "httpCallbacks"],
                  reason: nil)
    case .denied:
      return Self(mechanism: "unavailable", features: [], reason: "Notification permission denied")
    case .notDetermined:
      return Self(mechanism: "unavailable", features: [], reason: "Notification permission not granted")
    }
  }
}
