// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
// AF_UNIX control socket shared by the app (server) and the `updater` CLI (client). Ported from
// Talk & Read's Control.swift: one JSON line each way, a 0600 socket in an 0700 folder, same-user
// peers only (getpeereid), read deadlines and a replay cache for retried requests. Added here: a
// protocol version on every request and reply.

import Darwin
import Foundation

// MARK: Paths

enum ControlPaths {
  /// UPDATER_HOME moves everything for tests, so a test never talks to the real app.
  static var dataRoot: URL {
    if let home = ProcessInfo.processInfo.environment["UPDATER_HOME"], !home.isEmpty {
      return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Updater", isDirectory: true)
  }
  static var socket: URL { dataRoot.appendingPathComponent("control.sock") }
}

// MARK: Wire types

enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
  init(_ value: Int) { self = .number(Double(value)) }

  var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
  var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
  var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

extension JSONValue: ExpressibleByStringInterpolation, ExpressibleByBooleanLiteral {
  init(stringLiteral value: String) { self = .string(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// The wire format both sides speak. A reply always names the version it used.
let controlProtocolVersion = 1

struct ControlRequest: Codable, Sendable {
  var version: Int
  /// Client id, reused on retry; the replay key is (caller, id).
  var id: String
  var command: String
  var args: [String: String]
  var caller: String

  init(
    id: String = UUID().uuidString, command: String, args: [String: String] = [:],
    caller: String = "cli"
  ) {
    self.version = controlProtocolVersion
    self.id = id
    self.command = command
    self.args = args
    self.caller = caller
  }

  /// `version`, `id` and `command` are required; the rest default.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    id = try container.decode(String.self, forKey: .id)
    command = try container.decode(String.self, forKey: .command)
    args = try container.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
    caller = try container.decodeIfPresent(String.self, forKey: .caller) ?? "unknown"
  }
}

struct ControlResponse: Codable, Sendable {
  var version = controlProtocolVersion
  var ok: Bool
  var code: String?
  var message: String?
  var data: [String: JSONValue]?

  init(ok: Bool, code: String? = nil, message: String? = nil, data: [String: JSONValue]? = nil) {
    self.ok = ok
    self.code = code
    self.message = message
    self.data = data
  }

  static func failure(_ code: String, _ message: String) -> ControlResponse {
    ControlResponse(ok: false, code: code, message: message)
  }
}

/// Transport and start-up errors. Command failures are `ControlResponse`s.
struct ControlError: Error, Equatable, Sendable {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

// MARK: Socket helpers

private func errnoError(_ code: String, _ path: String) -> ControlError {
  ControlError(code, "\(path): \(String(cString: strerror(errno)))")
}

private func makeAddress(_ path: String) -> (sockaddr_un, socklen_t)? {
  let bytes = Array(path.utf8)
  guard bytes.count <= 103 else { return nil }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
      for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
      destination[bytes.count] = 0
    }
  }
  return (address, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1))
}

private func connectSocket(_ address: sockaddr_un, _ length: socklen_t, fd: Int32) -> Bool {
  withUnsafePointer(to: address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 }
  }
}

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func wait(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) -> Bool {
  while true {
    let left = deadline - uptime()
    guard left > 0 else { return false }
    var descriptor = pollfd(fd: fd, events: events, revents: 0)
    let result = poll(&descriptor, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
    if result > 0 { return true }
    if result < 0 && errno != EINTR { return false }
  }
}

private func writeAll(_ fd: Int32, _ data: Data, until deadline: TimeInterval) -> Bool {
  data.withUnsafeBytes { raw -> Bool in
    guard let base = raw.baseAddress else { return true }
    var sent = 0
    while sent < raw.count {
      let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
      if count > 0 {
        sent += count
        continue
      }
      if count < 0 && (errno == EAGAIN || errno == EINTR) {
        guard wait(fd, Int16(POLLOUT), until: deadline) else { return false }
        continue
      }
      return false
    }
    return true
  }
}

/// Reads up to the first newline; fails on timeout, close, or a line longer than `limit`.
private func readLine(_ fd: Int32, limit: Int, until deadline: TimeInterval) -> Result<
  Data, ControlError
> {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 65_536)
  while true {
    guard wait(fd, Int16(POLLIN), until: deadline) else {
      return .failure(ControlError("timeout", "Timed out waiting for a complete line."))
    }
    let count = recv(fd, &buffer, buffer.count, 0)
    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
    if count < 0 { return .failure(errnoError("socket_read_error", "recv")) }
    if count == 0 {
      return .failure(ControlError("closed", "The connection closed before a complete line."))
    }
    data.append(contentsOf: buffer[..<count])
    let newline = data.firstIndex(of: 10)
    if (newline.map { $0 - data.startIndex } ?? data.count) > limit {
      return .failure(ControlError("too_large", "Line exceeds \(limit) bytes."))
    }
    if let newline { return .success(data.prefix(upTo: newline)) }
  }
}

// MARK: Replay cache

/// The last 64 mutating (caller, id) keys for 5 minutes. A duplicate that arrives while the first
/// is still running waits for it and gets the same reply, so a retried `update` acts once.
actor ControlReplayCache {
  private struct Entry {
    let fingerprint: Int
    let task: Task<ControlResponse, Never>
    var finished: Date?
  }
  private var entries = [String: Entry]()
  private var order = [String]()
  private let ttl: TimeInterval
  private let limit: Int

  init(ttl: TimeInterval = 300, limit: Int = 64) {
    self.ttl = ttl
    self.limit = limit
  }

  func run(
    caller: String, id: String, fingerprint: Int,
    _ work: @escaping @Sendable () async -> ControlResponse
  ) async -> ControlResponse {
    let key = caller + "\u{0}" + id
    let cutoff = Date().addingTimeInterval(-ttl)
    for key in order where entries[key]?.finished.map({ $0 < cutoff }) == true { drop(key) }
    if let entry = entries[key] {
      guard entry.fingerprint == fingerprint else {
        return .failure(
          "request_id_conflict",
          "Request id \(id) was already used by \(caller) for a different request. Use a new id.")
      }
      var response = await entry.task.value
      response.data = (response.data ?? [:]).merging(["replayed": .bool(true)]) { $1 }
      return response
    }
    while entries.count >= limit, let oldest = order.first(where: { entries[$0]?.finished != nil })
    {
      drop(oldest)
    }
    let task = Task.detached { await work() }
    entries[key] = Entry(fingerprint: fingerprint, task: task, finished: nil)
    order.append(key)
    let response = await task.value
    entries[key]?.finished = Date()
    return response
  }

  private func drop(_ key: String) {
    entries[key] = nil
    order.removeAll { $0 == key }
  }
}

// MARK: Server

final class ControlServer: @unchecked Sendable {
  /// Only these change anything, so only these are replay-protected.
  static let mutatingCommands: Set<String> = ["check", "update"]
  static let maxRequest = 1_048_576
  static let maxResponse = 8_388_608

  private let path: String
  private let handler: @Sendable (ControlRequest) async -> ControlResponse
  private let cache = ControlReplayCache()
  private let requestTimeout: TimeInterval
  /// Tests pretend to be another user; production compares with this process's own UID.
  private let allowedUID: uid_t
  private let lock = NSLock()
  private var source: DispatchSourceRead?
  private var inode: ino_t = 0

  /// Binds and listens at once. A stale socket file is replaced; a live one is `already_running`.
  init(
    path: URL, requestTimeout: TimeInterval = 5, allowedUID: uid_t = getuid(),
    handler: @escaping @Sendable (ControlRequest) async -> ControlResponse
  ) throws {
    signal(SIGPIPE, SIG_IGN)  // a client that hangs up mid-reply must not kill the app
    self.path = path.path
    self.handler = handler
    self.requestTimeout = requestTimeout
    self.allowedUID = allowedUID
    let (listener, bound) = try Self.bind(self.path)
    inode = bound
    let readSource = DispatchSource.makeReadSource(
      fileDescriptor: listener,
      queue: DispatchQueue(label: "com.juniornkanabassi.Updater.control.accept"))
    readSource.setEventHandler { [weak self] in self?.acceptConnections(listener) }
    readSource.setCancelHandler { close(listener) }
    source = readSource
    readSource.resume()
  }

  func stop() {
    let (current, mine) = lock.withLock {
      defer {
        source = nil
        inode = 0
      }
      return (source, inode)
    }
    current?.cancel()
    var info = stat()
    if mine != 0, lstat(path, &info) == 0, info.st_ino == mine, (info.st_mode & S_IFMT) == S_IFSOCK
    {
      unlink(path)
    }
  }

  private static func bind(_ path: String) throws -> (Int32, ino_t) {
    guard let (address, length) = makeAddress(path) else {
      throw ControlError("socket_path_too_long", "Socket path must be at most 103 UTF-8 bytes.")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    do {
      try FileManager.default.createDirectory(
        atPath: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chmod(parent, 0o700) == 0 else { throw errnoError("socket_directory_error", parent) }
    } catch let error as ControlError {
      throw error
    } catch {
      throw ControlError("socket_directory_error", "Cannot create \(parent): \(error)")
    }

    var existing = stat()
    if lstat(path, &existing) == 0 {
      guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
        throw ControlError("socket_path_occupied", "A non-socket file is at \(path); remove it.")
      }
      let probe = socket(AF_UNIX, SOCK_STREAM, 0)
      guard probe >= 0 else { throw errnoError("socket_probe_error", path) }
      let live = connectSocket(address, length, fd: probe)
      let reason = errno
      close(probe)
      if live {
        throw ControlError("already_running", "An Updater is already listening at \(path).")
      }
      if reason != ECONNREFUSED && reason != ENOENT {
        throw ControlError(
          "socket_probe_error",
          "Cannot tell whether \(path) is stale: \(String(cString: strerror(reason))).")
      }
      guard unlink(path) == 0 else { throw errnoError("socket_path_error", path) }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw errnoError("socket_error", path) }
    func fail(_ code: String) -> ControlError {
      let error = errnoError(code, path)
      close(fd)
      return error
    }
    // Owner-only from the start: the mask covers the moment between bind and chmod.
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
    }
    umask(previousMask)
    guard bound == 0 else { throw fail("socket_bind_error") }
    guard chmod(path, 0o600) == 0, listen(fd, 32) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
      let error = fail("socket_listen_error")
      unlink(path)
      throw error
    }
    var info = stat()
    guard lstat(path, &info) == 0 else { throw fail("socket_stat_error") }
    return (fd, info.st_ino)
  }

  private func acceptConnections(_ listener: Int32) {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 { return }
      DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
    }
  }

  /// One request per connection. Reading has a deadline; the handler's own time is the client's.
  private func serve(_ client: Int32) {
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
    var noSignal: Int32 = 1
    _ = setsockopt(
      client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == allowedUID else {
      return finish(
        client, .failure("forbidden", "Only the user running Updater may use its control socket."))
    }
    switch readLine(client, limit: Self.maxRequest, until: uptime() + requestTimeout) {
    case .failure(let error):
      let code =
        error.code == "too_large"
        ? "request_too_large" : error.code == "timeout" ? "request_timeout" : "bad_request"
      finish(client, .failure(code, error.message))
    case .success(let line):
      guard let request = Self.decode(line) else {
        return finish(
          client,
          .failure(
            "bad_request",
            "Send one JSON object per line with version, id and command."))
      }
      guard request.version == controlProtocolVersion else {
        return finish(
          client,
          .failure(
            "unsupported_version",
            "This Updater speaks control protocol \(controlProtocolVersion); the request used \(request.version). Use the updater command from the same app."
          ))
      }
      Task.detached { [self] in
        let response = await dispatch(request)
        DispatchQueue.global(qos: .userInitiated).async { self.finish(client, response) }
      }
    }
  }

  private static func decode(_ line: Data) -> ControlRequest? {
    guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line),
      !request.id.isEmpty, !request.command.isEmpty
    else { return nil }
    return request
  }

  private func dispatch(_ request: ControlRequest) async -> ControlResponse {
    guard Self.mutatingCommands.contains(request.command) else { return await handler(request) }
    var hasher = Hasher()
    hasher.combine(request.command)
    for (key, value) in request.args.sorted(by: { $0.key < $1.key }) {
      hasher.combine(key)
      hasher.combine(value)
    }
    let handler = self.handler
    return await cache.run(caller: request.caller, id: request.id, fingerprint: hasher.finalize()) {
      await handler(request)
    }
  }

  private func finish(_ client: Int32, _ response: ControlResponse) {
    defer { close(client) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data =
      (try? encoder.encode(response)) ?? Data(#"{"ok":false,"code":"internal_error"}"#.utf8)
    if data.count > Self.maxResponse {
      data = Data(
        #"{"ok":false,"code":"response_too_large","message":"The reply is over 8 MB."}"#.utf8)
    }
    _ = writeAll(client, data + Data([10]), until: uptime() + 5)
  }
}

// MARK: Client

enum ControlClient {
  /// Sends one line of raw bytes and returns the reply line; used directly by protocol tests.
  static func exchange(_ payload: Data, with path: URL, timeout: Double) throws -> Data {
    let socketPath = path.path
    guard let (address, length) = makeAddress(socketPath) else {
      throw ControlError("socket_path_too_long", "Socket path must be at most 103 UTF-8 bytes.")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw errnoError("socket_error", socketPath) }
    defer { close(fd) }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    guard connectSocket(address, length, fd: fd) else {
      if errno == ENOENT || errno == ECONNREFUSED {
        throw ControlError("app_not_running", "Updater is not running (nothing at \(socketPath)).")
      }
      throw errnoError("socket_connect_error", socketPath)
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let deadline = uptime() + timeout
    guard writeAll(fd, payload, until: deadline) else {
      throw ControlError("timeout", "Could not send the request within \(Int(timeout)) s.")
    }
    switch readLine(fd, limit: ControlServer.maxResponse, until: deadline) {
    case .success(let line): return line
    case .failure(let error):
      switch error.code {
      case "timeout":
        throw ControlError(
          "timeout",
          "No reply within \(Int(timeout)) s. The request may still be running; retry with the same --request-id to get its result."
        )
      case "too_large":
        throw ControlError(
          "response_too_large", "Reply exceeds \(ControlServer.maxResponse) bytes.")
      default: throw ControlError("socket_read_error", "Updater closed the connection early.")
      }
    }
  }

  /// Sends one request and waits up to `timeout` seconds. Throws `ControlError`, notably
  /// `app_not_running` when nothing listens (then nothing was sent, so a retry is safe).
  static func send(_ request: ControlRequest, to path: URL, timeout: Double) throws
    -> ControlResponse
  {
    guard var payload = try? JSONEncoder().encode(request) else {
      throw ControlError("bad_request", "The request is not encodable.")
    }
    guard payload.count <= ControlServer.maxRequest else {
      throw ControlError("request_too_large", "Request exceeds \(ControlServer.maxRequest) bytes.")
    }
    payload.append(10)
    let line = try exchange(payload, with: path, timeout: timeout)
    guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else {
      throw ControlError("bad_response", "Updater returned invalid JSON.")
    }
    return response
  }
}
