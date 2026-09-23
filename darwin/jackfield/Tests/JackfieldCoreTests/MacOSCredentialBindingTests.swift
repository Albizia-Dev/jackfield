import Foundation
import XCTest
@testable import JackfieldCore

final class MacOSCredentialBindingTests: XCTestCase {
  func testPreparedRotationCannotPairNewTokenWithOldEndpoint() throws {
    let old = try XCTUnwrap(URL(string: "https://old.example.test/callback"))
    let next = try XCTUnwrap(URL(string: "https://new.example.test/callback"))
    let oldFingerprint = MacOSCredentialBinding.fingerprint(endpoint: old, token: "old-token")
    let newFingerprint = MacOSCredentialBinding.fingerprint(endpoint: next, token: "new-token")
    var vault = [oldFingerprint: "old-token"]

    vault[newFingerprint] = "new-token" // Keychain write completed; database commit has not.
    XCTAssertEqual(MacOSCredentialBinding.select(endpoint: old, committedFingerprint: oldFingerprint, tokenForFingerprint: { vault[$0] }), "old-token")
    XCTAssertEqual(MacOSCredentialBinding.select(endpoint: next, committedFingerprint: newFingerprint, tokenForFingerprint: { vault[$0] }), "new-token")
    XCTAssertNil(MacOSCredentialBinding.select(endpoint: old, committedFingerprint: newFingerprint, tokenForFingerprint: { vault[$0] }))

    vault[newFingerprint] = "corrupted-token"
    XCTAssertNil(MacOSCredentialBinding.select(endpoint: next, committedFingerprint: newFingerprint, tokenForFingerprint: { vault[$0] }))
  }

  func testCommittedEndpointAndFingerprintAreReadTogether() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try EventStore(path: path)
    try await store.configureHTTP(limit: 3, credentialFingerprint: "first", endpoint: "https://old.example.test/callback", ttl: 60)
    let first = try await store.httpDeliveryConfiguration()
    XCTAssertEqual(first?.configuration.endpoint, "https://old.example.test/callback")
    XCTAssertEqual(first?.fingerprint, "first")
    try await store.configureHTTP(limit: 3, credentialFingerprint: "second", endpoint: "https://new.example.test/callback", ttl: 90)
    let second = try await store.httpDeliveryConfiguration()
    XCTAssertEqual(second?.configuration.endpoint, "https://new.example.test/callback")
    XCTAssertEqual(second?.fingerprint, "second")
  }
}
