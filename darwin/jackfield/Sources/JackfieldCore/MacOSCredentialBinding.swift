import CryptoKit
import Foundation

/// Selects only the token whose identity was committed with the endpoint.
public enum MacOSCredentialBinding {
  public static func fingerprint(endpoint: URL, token: String) -> String {
    SHA256.hash(data: Data((endpoint.absoluteString + "\u{0}" + token).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  public static func select(endpoint: URL, committedFingerprint: String,
                            tokenForFingerprint: (String) -> String?) -> String? {
    guard let token = tokenForFingerprint(committedFingerprint),
          fingerprint(endpoint: endpoint, token: token) == committedFingerprint else { return nil }
    return token
  }
}
