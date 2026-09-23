import Foundation

public enum JackfieldCoreError: Error, Equatable {
  case protocolFailure, storageFull, invalidState, deadlineExceeded, platformFailure
}

public struct WireEnvelope: Codable, Equatable, Sendable {
  public let version: Int
  public let type: String
  public let callId: String
  public let eventId: String
  public let sequence: Int
  public let occurredAt: Date
  public let actionId: String?
  public let deadline: Date?
  public let reason: String?

  public static func answerRequested(callId: String, eventId: String, sequence: Int, actionId: String, occurredAt: Date, deadline: Date) throws -> Self {
    try Self(type: "answer_requested", callId: callId, eventId: eventId, sequence: sequence, occurredAt: occurredAt, actionId: actionId, deadline: deadline, reason: nil)
  }

  public static func ended(callId: String, eventId: String, sequence: Int, occurredAt: Date, reason: String) throws -> Self {
    try Self(type: "ended", callId: callId, eventId: eventId, sequence: sequence, occurredAt: occurredAt, actionId: nil, deadline: nil, reason: reason)
  }

  private init(type: String, callId: String, eventId: String, sequence: Int, occurredAt: Date, actionId: String?, deadline: Date?, reason: String?) throws {
    guard !callId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sequence >= 0 else { throw JackfieldCoreError.protocolFailure }
    if type == "answer_requested" {
      guard let actionId, !actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, deadline != nil, reason == nil else { throw JackfieldCoreError.protocolFailure }
    } else if type == "ended" {
      guard actionId == nil, deadline == nil, let reason, ["local", "remote", "rejected", "missed", "failed"].contains(reason) else { throw JackfieldCoreError.protocolFailure }
    } else { throw JackfieldCoreError.protocolFailure }
    self.version = 1; self.type = type; self.callId = callId; self.eventId = eventId
    self.sequence = sequence; self.occurredAt = occurredAt; self.actionId = actionId; self.deadline = deadline; self.reason = reason
  }

  public func toWire() -> [String: Any] {
    var value: [String: Any] = ["version": 1, "type": type, "callId": callId, "eventId": eventId, "sequence": sequence, "occurredAt": Self.timestamp(occurredAt)]
    if let actionId { value["actionId"] = actionId }
    if let deadline { value["deadline"] = Self.timestamp(deadline) }
    if let reason { value["reason"] = reason }
    return value
  }

  public static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

public struct ActionReceipt: Codable, Equatable, Sendable {
  public let actionId: String
  public let succeeded: Bool
  public let errorCode: String?
  public init(actionId: String, succeeded: Bool, errorCode: String? = nil) {
    self.actionId = actionId; self.succeeded = succeeded; self.errorCode = errorCode
  }
}

public struct CallRecord: Codable, Equatable, Sendable {
  public let callId: String
  public var state: String
  public var media: String
  public var callerId: String?
  public var callerName: String?
  public var actionId: String?
  public var actionDeadline: Date?
  public var actionReceipts: [ActionReceipt]
  public init(callId: String, state: String, media: String, callerId: String? = nil, callerName: String? = nil, actionId: String? = nil, actionDeadline: Date? = nil, actionReceipts: [ActionReceipt] = []) {
    self.callId = callId; self.state = state; self.media = media; self.callerId = callerId; self.callerName = callerName
    self.actionId = actionId; self.actionDeadline = actionDeadline; self.actionReceipts = actionReceipts
  }
  public func toWire() -> [String: Any] {
    var value: [String: Any] = ["callId": callId, "state": state, "media": media, "actionReceipts": actionReceipts.map { receipt in
      var item: [String: Any] = ["actionId": receipt.actionId, "succeeded": receipt.succeeded]
      if let code = receipt.errorCode { item["error"] = ["code": code] }
      return item
    }]
    if let callerId, let callerName { value["caller"] = ["id": callerId, "displayName": callerName] }
    if let actionId { value["actionId"] = actionId }
    if let actionDeadline { value["actionDeadline"] = WireEnvelope.timestamp(actionDeadline) }
    return value
  }
}
