import Foundation
import SQLite3

public actor EventStore {
  private var db: OpaquePointer?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(path: String) throws {
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw JackfieldCoreError.platformFailure }
    var versionStatement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
          sqlite3_step(versionStatement) == SQLITE_ROW else { sqlite3_finalize(versionStatement); throw JackfieldCoreError.platformFailure }
    let version = sqlite3_column_int(versionStatement, 0)
    sqlite3_finalize(versionStatement)
    guard version <= 1 else { throw JackfieldCoreError.protocolFailure }
    try Self.exec(db, "PRAGMA journal_mode=WAL")
    try Self.exec(db, "PRAGMA synchronous=FULL")
    if version == 0 {
      try Self.exec(db, "BEGIN IMMEDIATE")
      do {
        try Self.exec(db, "CREATE TABLE IF NOT EXISTS events (event_id TEXT PRIMARY KEY, call_id TEXT NOT NULL, sequence INTEGER NOT NULL, json BLOB NOT NULL, flutter_ack INTEGER NOT NULL DEFAULT 0, http_state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL DEFAULT 0)")
        try Self.exec(db, "CREATE TABLE IF NOT EXISTS calls (call_id TEXT PRIMARY KEY, json BLOB NOT NULL)")
        try Self.exec(db, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try Self.exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS events_call_sequence ON events(call_id,sequence)")
        try Self.exec(db, "PRAGMA user_version=1")
        try Self.exec(db, "COMMIT")
      } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
  }
  deinit { if let db { sqlite3_close(db) } }

  private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw JackfieldCoreError.platformFailure }
  }
  private func exec(_ sql: String) throws { try Self.exec(db, sql) }
  private func statement(_ sql: String) throws -> OpaquePointer? {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK else { throw JackfieldCoreError.platformFailure }
    return result
  }
  private func bind(_ text: String, _ index: Int32, to statement: OpaquePointer?) { sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
  private func bind(_ data: Data, _ index: Int32, to statement: OpaquePointer?) { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
  private func run(_ sql: String, _ args: [String]) throws {
    let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
    for (offset, value) in args.enumerated() { bind(value, Int32(offset + 1), to: stmt) }
    let outcome = sqlite3_step(stmt)
    guard outcome == SQLITE_DONE else { throw outcome == SQLITE_CONSTRAINT ? JackfieldCoreError.protocolFailure : JackfieldCoreError.platformFailure }
  }
  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do { let value = try body(); try exec("COMMIT"); return value }
    catch { try? exec("ROLLBACK"); throw error }
  }
  private func insert(_ event: WireEnvelope) throws {
    let prior = try statement("SELECT json FROM events WHERE event_id=?")
    bind(event.eventId, 1, to: prior)
    if sqlite3_step(prior) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(prior, 0) else { sqlite3_finalize(prior); throw JackfieldCoreError.platformFailure }
      let old = try decoder.decode(WireEnvelope.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(prior, 0))))
      sqlite3_finalize(prior)
      guard old == event else { throw JackfieldCoreError.protocolFailure }
      return
    }
    sqlite3_finalize(prior)
    if let limit = try setting("http_limit").flatMap(Int.init), try pendingHTTPCount() >= limit {
      throw JackfieldCoreError.storageFull
    }
    let httpState = try setting("http_enabled") == "0" ? "disabled" : "pending"
    let stmt = try statement("INSERT INTO events(event_id,call_id,sequence,json,http_state) VALUES(?,?,?,?,?)")
    defer { sqlite3_finalize(stmt) }
    bind(event.eventId, 1, to: stmt); bind(event.callId, 2, to: stmt)
    sqlite3_bind_int64(stmt, 3, Int64(event.sequence))
    bind(try encoder.encode(event), 4, to: stmt)
    bind(httpState, 5, to: stmt)
    let outcome = sqlite3_step(stmt)
    guard outcome == SQLITE_DONE else { throw outcome == SQLITE_CONSTRAINT ? JackfieldCoreError.protocolFailure : JackfieldCoreError.platformFailure }
  }
  private func put(_ snapshot: CallRecord) throws {
    let stmt = try statement("INSERT OR REPLACE INTO calls(call_id,json) VALUES(?,?)")
    defer { sqlite3_finalize(stmt) }
    bind(snapshot.callId, 1, to: stmt); bind(try encoder.encode(snapshot), 2, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw JackfieldCoreError.platformFailure }
  }
  public func append(_ event: WireEnvelope) throws { try transaction { try insert(event) } }
  public func schemaVersion() throws -> Int {
    let stmt = try statement("PRAGMA user_version"); defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw JackfieldCoreError.platformFailure }
    return Int(sqlite3_column_int(stmt, 0))
  }
  private func nextSequence(_ callId: String) throws -> Int {
    let stmt = try statement("SELECT COALESCE(MAX(sequence)+1,0) FROM events WHERE call_id=?")
    defer { sqlite3_finalize(stmt) }; bind(callId, 1, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw JackfieldCoreError.platformFailure }
    return Int(sqlite3_column_int64(stmt, 0))
  }
  public func appendEnded(callId: String, eventId: String, reason: String, at date: Date) throws -> WireEnvelope {
    try transaction {
      let event = try WireEnvelope.ended(callId: callId, eventId: eventId, sequence: try nextSequence(callId), occurredAt: date, reason: reason)
      try insert(event)
      return event
    }
  }
  public func saveAnswerRequested(callId: String, eventId: String, actionId: String, deadline: Date, at date: Date) throws -> WireEnvelope {
    try transaction {
      guard var record = try snapshot(callId: callId), record.state == "ringing" else { throw JackfieldCoreError.invalidState }
      let event = try WireEnvelope.answerRequested(callId: callId, eventId: eventId, sequence: try nextSequence(callId), actionId: actionId, occurredAt: date, deadline: deadline)
      record.state = "connecting"; record.actionId = actionId; record.actionDeadline = deadline
      try put(record); try insert(event)
      return event
    }
  }
  public func saveEnded(callId: String, eventId: String, reason: String, at date: Date) throws -> WireEnvelope {
    try transaction {
      guard var record = try snapshot(callId: callId), record.state != "ended" else { throw JackfieldCoreError.invalidState }
      let event = try WireEnvelope.ended(callId: callId, eventId: eventId, sequence: try nextSequence(callId), occurredAt: date, reason: reason)
      record.state = "ended"
      try put(record); try insert(event)
      return event
    }
  }
  public func save(snapshot: CallRecord, event: WireEnvelope) throws {
    guard snapshot.callId == event.callId else { throw JackfieldCoreError.protocolFailure }
    try transaction { try put(snapshot); try insert(event) }
  }
  public func save(snapshot: CallRecord) throws { try transaction { try put(snapshot) } }
  public func snapshot(callId: String) throws -> CallRecord? {
    let stmt = try statement("SELECT json FROM calls WHERE call_id=?")
    defer { sqlite3_finalize(stmt) }; bind(callId, 1, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
    return try decoder.decode(CallRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
  }
  public func allCallRecords() throws -> [CallRecord] {
    let stmt = try statement("SELECT json FROM calls"); defer { sqlite3_finalize(stmt) }
    var records: [CallRecord] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
      records.append(try decoder.decode(CallRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
    }
    return records
  }
  public func callId(for uuid: UUID) throws -> String? {
    try allCallRecords().first(where: { $0.systemUUID == uuid })?.callId
  }
  private func events(_ whereClause: String) throws -> [WireEnvelope] {
    let stmt = try statement("SELECT json FROM events WHERE \(whereClause) ORDER BY call_id,sequence")
    defer { sqlite3_finalize(stmt) }
    var result: [WireEnvelope] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
      result.append(try decoder.decode(WireEnvelope.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
    }
    return result
  }
  public func pendingFlutter() throws -> [WireEnvelope] { try events("flutter_ack=0") }
  public func pendingHTTP() throws -> [WireEnvelope] { try events("http_state='pending'") }
  public func allEvents(for callId: String) throws -> [WireEnvelope] {
    let stmt = try statement("SELECT json FROM events WHERE call_id=? ORDER BY sequence")
    defer { sqlite3_finalize(stmt) }; bind(callId, 1, to: stmt)
    var result: [WireEnvelope] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
      result.append(try decoder.decode(WireEnvelope.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
    }
    return result
  }
  public func acknowledgeFlutter(_ ids: Set<String>) throws { try transaction { for id in ids { try run("UPDATE events SET flutter_ack=1 WHERE event_id=?", [id]) } } }
  public func acknowledgeHTTP(_ ids: Set<String>) throws { try transaction { for id in ids { try run("UPDATE events SET http_state='acknowledged' WHERE event_id=?", [id]) } } }
  public func completeAction(_ actionId: String, succeeded: Bool, at now: Date) throws -> ActionReceipt {
    let stmt = try statement("SELECT json FROM calls")
    defer { sqlite3_finalize(stmt) }
    var found: CallRecord?
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
      let item = try decoder.decode(CallRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
      if item.actionId == actionId { found = item; break }
    }
    guard var record = found else { throw JackfieldCoreError.invalidState }
    if let prior = record.actionReceipts.first(where: { $0.actionId == actionId }) { return prior }
    guard record.state == "connecting", let deadline = record.actionDeadline else { throw JackfieldCoreError.invalidState }
    let expired = now > deadline
    let receipt = ActionReceipt(actionId: actionId, succeeded: succeeded && !expired, errorCode: expired ? "deadlineExceeded" : nil)
    record.actionReceipts.append(receipt)
    record.state = expired ? "failed" : (succeeded ? "active" : "failed")
    try transaction { try put(record) }
    return receipt
  }
  public func pendingHTTPCount() throws -> Int { try count("http_state='pending'") }
  public func pendingFlutterCount() throws -> Int { try count("flutter_ack=0") }
  private func count(_ clause: String) throws -> Int {
    let stmt = try statement("SELECT COUNT(*) FROM events WHERE \(clause)"); defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw JackfieldCoreError.platformFailure }
    return Int(sqlite3_column_int64(stmt, 0))
  }
  private func setting(_ key: String) throws -> String? {
    let stmt = try statement("SELECT value FROM settings WHERE key=?")
    defer { sqlite3_finalize(stmt) }; bind(key, 1, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return String(cString: sqlite3_column_text(stmt, 0))
  }
  public func configureHTTP(limit: Int, credentialFingerprint: String? = nil, endpoint: String? = nil, ttl: TimeInterval? = nil) throws {
    guard limit > 0 else { throw JackfieldCoreError.protocolFailure }
    if let endpoint, let ttl {
      guard endpoint.hasPrefix("https://"), ttl > 0 else { throw JackfieldCoreError.protocolFailure }
    } else if endpoint != nil || ttl != nil { throw JackfieldCoreError.protocolFailure }
    try transaction {
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('http_limit',?)", [String(limit)])
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('http_enabled','1')", [])
      if let endpoint, let ttl {
        try run("INSERT OR REPLACE INTO settings(key,value) VALUES('http_endpoint',?)", [endpoint])
        try run("INSERT OR REPLACE INTO settings(key,value) VALUES('http_ttl',?)", [String(ttl)])
      }
      if let credentialFingerprint, !credentialFingerprint.isEmpty {
        try run("INSERT OR REPLACE INTO settings(key,value) VALUES('credential_fingerprint',?)", [credentialFingerprint])
      }
    }
  }
  public func disableHTTP() throws {
    try transaction {
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('http_enabled','0')", [])
      try exec("UPDATE events SET http_state='disabled' WHERE http_state='pending'")
      try exec("DELETE FROM settings WHERE key IN ('http_endpoint','http_ttl','credential_fingerprint','rejected_fingerprint','auth_pause')")
    }
  }
  public func httpConfiguration() throws -> HTTPConfiguration? {
    guard try setting("http_enabled") == "1",
          let endpoint = try setting("http_endpoint"),
          let ttlText = try setting("http_ttl"), let ttl = TimeInterval(ttlText),
          let limitText = try setting("http_limit"), let limit = Int(limitText) else { return nil }
    return HTTPConfiguration(endpoint: endpoint, ttl: ttl, limit: limit)
  }
  public func httpPausedForAuthentication() throws -> Bool {
    try setting("auth_pause") == "1"
  }
  public func pauseHTTPForAuthentication(using fingerprint: String) throws {
    try transaction {
      guard try setting("credential_fingerprint") == fingerprint else { return }
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('auth_pause','1')", [])
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('rejected_fingerprint',?)", [fingerprint])
    }
  }
  public func resumeHTTPAfterCredentialRotation() throws {
    guard let current = try setting("credential_fingerprint"),
          let rejected = try setting("rejected_fingerprint"), current != rejected else { return }
    try transaction {
      try run("INSERT OR REPLACE INTO settings(key,value) VALUES('auth_pause','0')", [])
      try run("DELETE FROM settings WHERE key='rejected_fingerprint'", [])
    }
  }
  public func markHTTPTerminal(_ id: String) throws { try run("UPDATE events SET http_state='terminal' WHERE event_id=?", [id]) }
  public func scheduleHTTP(_ id: String, at date: Date) throws {
    let stmt = try statement("UPDATE events SET attempts=attempts+1,next_at=? WHERE event_id=?")
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970); bind(id, 2, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw JackfieldCoreError.platformFailure }
  }
  public func httpAttempts(_ id: String) throws -> Int {
    let stmt = try statement("SELECT attempts FROM events WHERE event_id=?")
    defer { sqlite3_finalize(stmt) }; bind(id, 1, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw JackfieldCoreError.invalidState }
    return Int(sqlite3_column_int64(stmt, 0))
  }
  public func nextHTTPWake() throws -> Date? {
    let paused = try httpPausedForAuthentication()
    let ttl = try httpConfiguration()?.ttl
    let stmt = try statement("SELECT next_at,json FROM events WHERE http_state='pending'")
    defer { sqlite3_finalize(stmt) }
    var earliest: Date?
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 1) else { throw JackfieldCoreError.platformFailure }
      let event = try decoder.decode(WireEnvelope.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1))))
      let expiration = ttl.map { event.occurredAt.addingTimeInterval($0) }
      let retry = paused ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
      for candidate in [expiration, retry].compactMap({ $0 }) {
        if let current = earliest { earliest = min(current, candidate) }
        else { earliest = candidate }
      }
    }
    return earliest
  }
  public func expireHTTP(at date: Date) throws {
    guard let ttl = try httpConfiguration()?.ttl else { return }
    let pending = try pendingHTTP()
    try transaction {
      for event in pending where date >= event.occurredAt.addingTimeInterval(ttl) {
        try run("UPDATE events SET http_state='terminal' WHERE event_id=? AND http_state='pending'", [event.eventId])
      }
    }
  }
  public func readyHTTP(at date: Date) throws -> [WireEnvelope] {
    if try httpPausedForAuthentication() { return [] }
    let stmt = try statement("SELECT e.json FROM events e WHERE e.http_state='pending' AND e.next_at<=? AND NOT EXISTS (SELECT 1 FROM events prior WHERE prior.call_id=e.call_id AND prior.sequence<e.sequence AND prior.http_state='pending') ORDER BY e.call_id,e.sequence")
    defer { sqlite3_finalize(stmt) }; sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
    var result: [WireEnvelope] = []; var seen: Set<String> = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(stmt, 0) else { throw JackfieldCoreError.platformFailure }
      let event = try decoder.decode(WireEnvelope.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
      if seen.insert(event.callId).inserted { result.append(event) }
    }
    return result
  }
}
