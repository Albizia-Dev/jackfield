import Foundation
import PushKit

@available(iOS 13.0, *)
final class JackfieldPushRegistry: NSObject, PKPushRegistryDelegate {
  private let registry = PKPushRegistry(queue: .main)
  private let incoming: (String, String, String, String, @escaping () -> Void) -> Void
  private let tokenChanged: (String?, Bool) -> Void

  init(incoming: @escaping (String, String, String, String, @escaping () -> Void) -> Void,
       tokenChanged: @escaping (String?, Bool) -> Void) {
    self.incoming = incoming; self.tokenChanged = tokenChanged
    super.init()
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    tokenChanged(pushCredentials.token.map { String(format: "%02x", $0) }.joined(), false)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    tokenChanged(nil, true)
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP,
          let data = payload.dictionaryPayload["jackfield"] as? [String: Any],
          let callId = data["callId"] as? String, !callId.isEmpty,
          let caller = data["caller"] as? [String: String],
          let callerId = caller["id"], !callerId.isEmpty,
          let name = caller["displayName"], !name.isEmpty,
          let media = data["media"] as? String, ["audio", "video"].contains(media)
    else { completion(); return }
    incoming(callId, callerId, name, media, completion)
  }
}
