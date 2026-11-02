// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
// `updater` (Contents/Helpers/updater): controls the running Updater over its socket, after
// Talk & Read's talkread helper. Exit codes: 0 ok, 1 Updater refused or failed, 2 usage,
// 3 Updater is not running and could not be started.

import Darwin
import Foundation

// MARK: Command table (also the MCP tool list: `updater mcp-manifest`)

struct Param {
  enum Kind { case string, integer, switchFlag }
  let name: String
  let kind: Kind
  let help: String
  var required = false
  var positional = false
}

struct Command {
  let name: String
  let summary: String
  let example: String
  var params: [Param] = []
  var timeout: Double = 30
}

let commands: [Command] = [
  Command(
    name: "list",
    summary:
      "List the apps Updater found, with installed and available versions, capability (install, vendorTool, handOff, unsupported) and any running job id. Read-only.",
    example: "list --updates",
    params: [Param(name: "updates", kind: .switchFlag, help: "Only apps with an update waiting.")],
    timeout: 60),
  Command(
    name: "check",
    summary:
      "Check every app for updates and wait for the result (joins a check already running). Never installs.",
    example: "check --refresh",
    params: [
      Param(
        name: "refresh", kind: .switchFlag, help: "Skip cached App Store and Homebrew answers."),
      Param(name: "wait", kind: .integer, help: "Seconds to wait for it, 0 to 600; default 120."),
    ], timeout: 630),
  Command(
    name: "update",
    summary:
      "Update one app (bundle id or path) or all. Returns a job id per app; a target already updating returns its job as inProgress, and jobs sharing a tool wait their turn. Apps that update elsewhere come back as handOff with the label unless --allow-handoff is given; Update All never hands off. A running app is only quit after the user confirms in Updater; otherwise the job ends as needsQuit.",
    example: "update com.example.App",
    params: [
      Param(
        name: "target", kind: .string, help: "Bundle id, app path, or all.", required: true,
        positional: true),
      Param(
        name: "allow-handoff", kind: .switchFlag,
        help:
          "Open the app's own updater (App Store, Creative Cloud, Terminal) for one hand-off app."),
    ]),
  Command(
    name: "status",
    summary:
      "Without a job id: whether a check is running, how many updates wait, and recent jobs. With one: that job's state (waiting, running, updated, noChange, failed, needsQuit, needsPermission).",
    example: "status 3f2c…",
    params: [
      Param(name: "job", kind: .string, help: "Job id from `updater update`.", positional: true)
    ]),
  Command(
    name: "history",
    summary: "Recorded update outcomes, newest first. Read-only.",
    example: "history --limit 10",
    params: [Param(name: "limit", kind: .integer, help: "1 to 500; default 20.")]),
]

// MARK: Output

nonisolated(unsafe) var json = false
let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return encoder
}()

func printJSON(_ response: ControlResponse) {
  if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
}

func stderrLine(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func fail(_ code: String, _ message: String, exit status: Int32) -> Never {
  if json { printJSON(.failure(code, message)) } else { stderrLine("\(code): \(message)") }
  exit(status)
}

func usage(_ message: String, _ command: Command?) -> Never {
  fail("usage", message + " Try: updater \(command?.name ?? "") --help", exit: 2)
}

func text(_ value: JSONValue?) -> String? {
  switch value {
  case .string(let string)?: return string
  case .number(let number)?: return String(Int(number))
  case .bool(let bool)?: return bool ? "yes" : "no"
  default: return nil
  }
}

/// Short human lines; --json prints the reply as is.
func render(_ response: ControlResponse, command: String) {
  let data = response.data ?? [:]
  if let message = response.message { print(message) }
  switch command {
  case "list":
    let apps = data["apps"]?.arrayValue ?? []
    for app in apps.compactMap(\.objectValue) {
      let versions = [text(app["installed"]), text(app["available"]).map { "→ \($0)" }]
        .compactMap { $0 }.joined(separator: " ")
      let notes = [
        text(app["capability"]), text(app["handOffLabel"]), text(app["jobId"]).map { "job \($0)" },
      ].compactMap { $0 }.joined(separator: ", ")
      print("\(text(app["name"]) ?? "?")  \(versions)  (\(notes))  \(text(app["path"]) ?? "")")
    }
    if apps.isEmpty { print("No apps.") }
  case "update":
    for result in (data["results"]?.arrayValue ?? []).compactMap(\.objectValue) {
      let details = [
        text(result["jobId"]).map { "job \($0)" }, text(result["state"]), text(result["label"]),
      ]
      .compactMap { $0 }.joined(separator: ", ")
      print(
        "\(text(result["name"]) ?? "?"): \(text(result["status"]) ?? "")"
          + (details.isEmpty ? "" : " (\(details))")
          + (text(result["message"]).map { ". \($0)" } ?? ""))
    }
  case "status":
    if let job = data["job"]?.objectValue {
      print(jobLine(job))
    } else {
      print(
        "Checking: \(text(data["checking"]) ?? "no"). Updates available: \(text(data["updatesAvailable"]) ?? "0")."
      )
      for job in (data["jobs"]?.arrayValue ?? []).compactMap(\.objectValue) { print(jobLine(job)) }
    }
  case "history":
    let entries = (data["entries"]?.arrayValue ?? []).compactMap(\.objectValue)
    for entry in entries {
      let change = [text(entry["from"]), text(entry["to"])].compactMap { $0 }.joined(
        separator: " → ")
      print(
        [
          text(entry["date"]), text(entry["name"]), text(entry["state"]), change,
          text(entry["message"]),
        ]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  "))
    }
    if entries.isEmpty { print("No history yet.") }
  default: break
  }
}

func jobLine(_ job: [String: JSONValue]) -> String {
  [
    text(job["jobId"]), text(job["name"]), text(job["state"]),
    [text(job["from"]), text(job["to"])].compactMap { $0 }.joined(separator: " → "),
    text(job["message"]),
  ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
}

func help(_ command: Command? = nil) {
  guard let command else {
    print(
      "updater <command> [options]   Control Updater from the shell. A closed Updater starts in the background with no window."
    )
    for command in commands {
      print(
        "  \(command.name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(command.summary)")
    }
    print("  help      This text; `updater <command> --help` for one command with an example.")
    print(
      "Global options: --json  --caller <name>  --request-id <id>  --timeout <seconds>  --help")
    print(
      "Exit codes: 0 ok, 1 Updater refused or failed, 2 usage, 3 Updater is not running and could not be started."
    )
    return
  }
  let positional = command.params.filter(\.positional).map {
    $0.required ? "<\($0.name)>" : "[\($0.name)]"
  }
  let flags = command.params.filter { !$0.positional }.map {
    $0.kind == .switchFlag ? "[--\($0.name)]" : "[--\($0.name) <\($0.name)>]"
  }
  print((["updater", command.name] + positional + flags + ["[--json]"]).joined(separator: " "))
  print(command.summary)
  for param in command.params {
    print("  \(param.positional ? param.name : "--" + param.name): \(param.help)")
  }
  print("Example: updater \(command.example)")
}

func manifest() {
  func schema(_ param: Param) -> [String: Any] {
    let type =
      switch param.kind {
      case .string: "string"
      case .integer: "integer"
      case .switchFlag: "boolean"
      }
    return ["type": type, "description": param.help]
  }
  let tools: [[String: Any]] = commands.map { command in
    [
      "name": command.name, "description": command.summary,
      "inputSchema": [
        "type": "object",
        "properties": Dictionary(
          uniqueKeysWithValues: command.params.map { ($0.name, schema($0)) }),
        "required": command.params.filter(\.required).map(\.name),
        "additionalProperties": false,
      ] as [String: Any],
    ]
  }
  guard let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]) else {
    fail("internal_error", "Could not encode the tool list.", exit: 1)
  }
  print(String(decoding: data, as: UTF8.self))
}

// MARK: Parse

let argv = Array(CommandLine.arguments.dropFirst())
json = argv.contains("--json")
let globalValueOptions: Set<String> = ["caller", "request-id", "timeout"]

/// The command is the first bare word that is not the value of a global option.
func commandName() -> String? {
  var index = 0
  while index < argv.count {
    let argument = argv[index]
    index += 1
    if argument.hasPrefix("--") {
      let name = String(argument.dropFirst(2))
      if globalValueOptions.contains(name) { index += 1 }
      continue
    }
    if argument != "-h" { return argument }
  }
  return nil
}

guard let first = commandName() else {
  if argv.isEmpty || argv.contains("--help") || argv.contains("-h") {
    help()
    exit(0)
  }
  usage("Missing command.", nil)
}
if first == "help" {
  let topic = argv.drop { $0 != "help" }.dropFirst().first
  help(topic.flatMap { name in commands.first { $0.name == name } })
  exit(0)
}
if first == "mcp-manifest" {
  manifest()
  exit(0)
}
guard let command = commands.first(where: { $0.name == first }) else {
  usage("Unknown command \(first).", nil)
}

var wantHelp = false
var caller: String?
var requestID: String?
var timeoutOverride: Double?
var args = [String: String]()
var rest = [String]()
var seenCommand = false
var index = 0
while index < argv.count {
  let argument = argv[index]
  index += 1
  if argument == "-h" || argument == "--help" {
    wantHelp = true
    continue
  }
  guard argument.hasPrefix("--") else {
    if !seenCommand && argument == first {
      seenCommand = true
    } else {
      rest.append(argument)
    }
    continue
  }
  if argument == "--json" { continue }
  let parts = argument.dropFirst(2).split(
    separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
  let name = String(parts[0])
  var inline = parts.count == 2 ? String(parts[1]) : nil
  // Positional parameters may also come as --name=value (the MCP adapter sends them so).
  let param = command.params.first { $0.name == name }
  if param?.kind == .switchFlag {
    // A plain switch; the MCP adapter sends --name=true or --name=false.
    guard args[name] == nil else { usage("Repeated --\(name).", command) }
    switch inline?.lowercased() ?? "true" {
    case "true", "1": args[name] = "1"
    case "false", "0": break
    default: usage("--\(name) takes no value.", command)
    }
    continue
  }
  guard param != nil || globalValueOptions.contains(name) else {
    usage("Unknown option --\(name).", command)
  }
  if inline == nil {
    guard index < argv.count else { usage("Missing value for --\(name).", command) }
    inline = argv[index]
    index += 1
  }
  guard let value = inline else { usage("Missing value for --\(name).", command) }
  switch name {
  case "caller": caller = value
  case "request-id": requestID = value
  case "timeout":
    guard let seconds = Double(value), seconds > 0 else {
      usage("--timeout must be positive.", nil)
    }
    timeoutOverride = seconds
  default:
    guard args[name] == nil else { usage("Repeated --\(name).", command) }
    if param?.kind == .integer, Int(value) == nil {
      usage("--\(name) must be a whole number.", command)
    }
    args[name] = value
  }
}
if wantHelp {
  help(command)
  exit(0)
}
for param in command.params where param.positional && !rest.isEmpty {
  var value = rest.removeFirst()
  if param.name == "target", value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
    value = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
  }
  args[param.name] = value
}
if let extra = rest.first { usage("Unexpected argument \(extra).", command) }
for param in command.params where param.required && args[param.name] == nil {
  usage("Missing \(param.name).", command)
}

// MARK: Run

let request = ControlRequest(
  id: requestID ?? UUID().uuidString, command: command.name, args: args,
  caller: caller ?? "cli-\(getppid())")
let timeout = timeoutOverride ?? command.timeout

/// Whether this helper's own app (or, outside a bundle, any Updater) is running.
func appRunning(exact: String?) -> Bool {
  var pids = [pid_t](repeating: 0, count: 4096)
  let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
  var path = [CChar](repeating: 0, count: 4096)
  for pid in pids.prefix(max(0, count)) where pid > 0 && pid != getpid() {
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
    let running = String(cString: path)
    if let exact {
      if running == exact || running == "/private" + exact { return true }
    } else if running.hasSuffix("/Updater.app/Contents/MacOS/Updater") {
      return true
    }
  }
  return false
}

/// Starts a closed Updater in the background (no window, no focus) and sends once its socket
/// answers. Only `app_not_running` is retried, which means nothing was sent.
func launchAndSend() throws -> ControlResponse {
  let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath()
  let app = executable.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let inBundle = app.pathExtension == "app"
  try? FileManager.default.createDirectory(
    at: ControlPaths.dataRoot, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  // Two CLIs finding Updater closed at once open it one at a time; a second `open` of an app
  // that is still starting would send it a reopen, which shows the window.
  let lock = Darwin.open(
    ControlPaths.dataRoot.appendingPathComponent("cli-launch.lock").path, O_CREAT | O_RDWR, 0o600)
  guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
    throw ControlError("launch_lock_failed", "Could not take the launch lock.")
  }
  let own = inBundle ? app.appendingPathComponent("Contents/MacOS/Updater").path : nil
  if !appRunning(exact: own) {
    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments =
      ["-g"] + (inBundle ? ["-a", app.path] : ["-b", "com.juniornkanabassi.Updater"])
      + ["--args", "--headless"]
    launch.standardOutput = FileHandle.nullDevice
    launch.standardError = FileHandle.nullDevice
    try launch.run()
    launch.waitUntilExit()
    guard launch.terminationStatus == 0 else {
      close(lock)
      throw ControlError("app_not_running", "Updater is not running and could not be started.")
    }
  }
  close(lock)
  let deadline = Date().addingTimeInterval(30)
  while true {
    do {
      return try ControlClient.send(request, to: ControlPaths.socket, timeout: timeout)
    } catch let error as ControlError where error.code == "app_not_running" && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
  }
}

do {
  let response: ControlResponse
  do {
    response = try ControlClient.send(request, to: ControlPaths.socket, timeout: timeout)
  } catch let error as ControlError
    where error.code == "app_not_running"
    // A test root (UPDATER_HOME) never starts the real app.
    && ProcessInfo.processInfo.environment["UPDATER_HOME"] == nil
  {
    response = try launchAndSend()
  }
  if json {
    printJSON(response)
  } else if response.ok {
    render(response, command: command.name)
  } else {
    stderrLine("\(response.code ?? "error"): \(response.message ?? "The request failed.")")
  }
  exit(response.ok ? 0 : 1)
} catch let error as ControlError {
  fail(error.code, error.message, exit: error.code == "app_not_running" ? 3 : 1)
} catch {
  fail("failed", "\(error)", exit: 1)
}
