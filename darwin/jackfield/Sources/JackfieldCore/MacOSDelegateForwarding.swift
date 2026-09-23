import Foundation

/// Supplies the OS completion when an optional host delegate method is absent.
public enum MacOSDelegateForwarding {
  public static func forward(optionalCall: () -> Void?, fallback: () -> Void) {
    if optionalCall() == nil { fallback() }
  }
}
