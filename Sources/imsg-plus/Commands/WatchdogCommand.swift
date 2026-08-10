import Commander
import Foundation
import IMsgCore

enum WatchdogCommand {
  static let launchAgentLabel = "com.imsg-plus.watchdog"
  static let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
  static let logPath = NSHomeDirectory() + "/Library/Logs/imsg-plus-watchdog.log"
  static let maximumLogBytes: UInt64 = 10 * 1024 * 1024
  static let incidentScanBytes: UInt64 = 256 * 1024

  // Error patterns that indicate Messages.app sync issues
  static let errorPatterns = [
    "Unable to send to server",
    "PSC out of sync",
  ]

  static let spec = CommandSpec(
    name: "watchdog",
    abstract: "Monitor and auto-heal Messages.app sync issues",
    discussion: """
      Monitors macOS imagent logs for sync failures and automatically
      restarts Messages.app with dylib injection when issues are detected.

      Running `imsg-plus watchdog` will:
        - Check if the watchdog LaunchAgent is installed
        - Install it if missing
        - Start it if not running
        - Show current status

      The watchdog runs as a background LaunchAgent that survives reboots.
      When it detects a specific imagent send or sync failure, it automatically runs
      `imsg-plus launch` to restart Messages.app with proper dylib injection.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        flags: [
          .make(
            label: "status", names: [.long("status")],
            help: "Just show status, don't install or start"),
          .make(
            label: "uninstall", names: [.long("uninstall")],
            help: "Stop and uninstall the watchdog"),
          .make(
            label: "run", names: [.long("run")],
            help: "Run the watchdog in foreground (used by LaunchAgent)"),
          .make(
            label: "logs", names: [.long("logs")],
            help: "Tail the watchdog log"),
        ]
      )
    ),
    usageExamples: [
      "imsg-plus watchdog",
      "imsg-plus watchdog --status",
      "imsg-plus watchdog --uninstall",
      "imsg-plus watchdog --logs",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let statusOnly = values.flags.contains("status")
    let uninstall = values.flags.contains("uninstall")
    let runDaemon = values.flags.contains("run")
    let showLogs = values.flags.contains("logs")

    if showLogs {
      try await tailLogs(runtime: runtime)
      return
    }

    if runDaemon {
      try await runWatchdogLoop(runtime: runtime)
      return
    }

    if uninstall {
      try await uninstallWatchdog(runtime: runtime)
      return
    }

    if statusOnly {
      try await showStatus(runtime: runtime)
      return
    }

    // Default: ensure installed and running
    try await ensureRunning(runtime: runtime)
  }

  // MARK: - Status

  static func showStatus(runtime: RuntimeOptions) async throws {
    let installed = isInstalled()
    let running = isRunning()
    let pid = getRunningPid()
    let lastIncident = getLastIncident()

    if runtime.jsonOutput {
      var output: [String: Any] = [
        "installed": installed,
        "running": running,
        "launch_agent_path": launchAgentPath,
        "log_path": logPath,
      ]
      if let pid = pid {
        output["pid"] = pid
      }
      if let incident = lastIncident {
        output["last_incident"] = incident
      }
      print(JSONSerialization.string(from: output))
    } else {
      print("imsg-plus Watchdog Status")
      print("=========================")
      print()
      print("LaunchAgent: \(installed ? "✅ installed" : "❌ not installed")")
      print("Process:     \(running ? "✅ running (pid \(pid ?? 0))" : "❌ not running")")
      print()
      print("Paths:")
      print("  LaunchAgent: \(launchAgentPath)")
      print("  Log file:    \(logPath)")
      if let incident = lastIncident {
        print()
        print("Last incident: \(incident)")
      }
    }
  }

  // MARK: - Ensure Running

  static func ensureRunning(runtime: RuntimeOptions) async throws {
    let installed = isInstalled()
    let running = isRunning()

    if installed && running {
      // Already good
      if !runtime.jsonOutput {
        let pid = getRunningPid() ?? 0
        print("✅ Watchdog is running (pid \(pid))")
        print()
        print("Monitoring imagent for sync failures.")
        print("Will auto-restart Messages.app when errors detected.")
        print()
        print("Log: \(logPath)")
      } else {
        let output: [String: Any] = [
          "success": true,
          "action": "none",
          "message": "Watchdog already running",
          "pid": getRunningPid() ?? 0,
        ]
        print(JSONSerialization.string(from: output))
      }
      return
    }

    // Need to install
    if !installed {
      if !runtime.jsonOutput {
        print("📦 Installing watchdog LaunchAgent...")
      }
      try installLaunchAgent()
      if !runtime.jsonOutput {
        print("   ✅ Installed")
      }
    }

    // Need to start
    if !isRunning() {
      if !runtime.jsonOutput {
        print("🚀 Starting watchdog...")
      }
      try truncateOversizedLogBeforeStart()
      try startLaunchAgent()

      // Wait a moment for it to start
      try await Task.sleep(nanoseconds: 1_000_000_000)

      if isRunning() {
        if !runtime.jsonOutput {
          print("   ✅ Started")
        }
      } else {
        if !runtime.jsonOutput {
          print("   ⚠️  May have failed to start. Check: launchctl list | grep imsg-plus")
        }
      }
    }

    if runtime.jsonOutput {
      let output: [String: Any] = [
        "success": true,
        "action": installed ? "started" : "installed_and_started",
        "message": "Watchdog is now running",
        "pid": getRunningPid() ?? 0,
      ]
      print(JSONSerialization.string(from: output))
    } else {
      print()
      print("✅ Watchdog is now running")
      print()
      print("Monitoring imagent for sync failures.")
      print("Will auto-restart Messages.app when errors detected.")
      print()
      print("Log: \(logPath)")
    }
  }

  // MARK: - Uninstall

  static func uninstallWatchdog(runtime: RuntimeOptions) async throws {
    if !runtime.jsonOutput {
      print("🛑 Stopping watchdog...")
    }

    if isRunning() {
      try stopLaunchAgent()
      try await Task.sleep(nanoseconds: 500_000_000)
    }

    if !runtime.jsonOutput {
      print("🗑️  Removing LaunchAgent...")
    }

    if FileManager.default.fileExists(atPath: launchAgentPath) {
      try FileManager.default.removeItem(atPath: launchAgentPath)
    }

    if runtime.jsonOutput {
      let output: [String: Any] = [
        "success": true,
        "action": "uninstalled",
        "message": "Watchdog uninstalled",
      ]
      print(JSONSerialization.string(from: output))
    } else {
      print()
      print("✅ Watchdog uninstalled")
    }
  }

  // MARK: - Daemon Loop

  static func runWatchdogLoop(runtime: RuntimeOptions) async throws {
    log("Watchdog starting...")
    log("Monitoring imagent for: \(errorPatterns.joined(separator: ", "))")

    let cooldownSeconds: TimeInterval = 300  // 5 minutes
    var lastRestartTime: Date? = nil

    // Use log stream to monitor imagent
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["stream", "--predicate", "process == \"imagent\"", "--style", "compact"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    try process.run()

    let handle = pipe.fileHandleForReading

    for try await line in handle.bytes.lines {
      guard let pattern = matchingErrorPattern(in: line) else { continue }
      log("ERROR DETECTED: \(pattern)")

      if let lastRestart = lastRestartTime,
        Date().timeIntervalSince(lastRestart) < cooldownSeconds
      {
        let elapsed = Int(Date().timeIntervalSince(lastRestart))
        log("SKIP: Cooldown active (\(elapsed)s since last restart)")
        continue
      }

      log("RESTARTING: Running imsg-plus launch...")

      let launchProcess = Process()
      launchProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/imsg-plus")
      launchProcess.arguments = ["launch", "--quiet"]
      try? launchProcess.run()
      launchProcess.waitUntilExit()

      lastRestartTime = Date()

      if launchProcess.terminationStatus == 0 {
        log("RESTARTED: Messages.app restarted successfully")
      } else {
        log("WARNING: imsg-plus launch exited with status \(launchProcess.terminationStatus)")
      }
    }

    log("Watchdog exiting (log stream ended)")
  }

  // MARK: - Tail Logs

  static func tailLogs(runtime: RuntimeOptions) async throws {
    guard FileManager.default.fileExists(atPath: logPath) else {
      print("No log file found at: \(logPath)")
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    process.arguments = ["-f", logPath]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()
  }

  // MARK: - Helpers

  static func isInstalled() -> Bool {
    return FileManager.default.fileExists(atPath: launchAgentPath)
  }

  static func isRunning() -> Bool {
    return getRunningPid() != nil
  }

  static func getRunningPid() -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["list"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    try? process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }

    for line in output.components(separatedBy: "\n") {
      if line.contains(launchAgentLabel) {
        let parts = line.components(separatedBy: "\t")
        if parts.count >= 1, let pid = Int(parts[0]), pid > 0 {
          return pid
        }
      }
    }
    return nil
  }

  static func matchingErrorPattern(in line: String) -> String? {
    for pattern in errorPatterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      else { continue }
      if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
        return pattern
      }
    }
    return nil
  }

  static func getLastIncident(path: String = logPath) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    let data: Data
    let startedMidFile: Bool
    do {
      let end = try handle.seekToEnd()
      let start = end > incidentScanBytes ? end - incidentScanBytes : 0
      startedMidFile = start > 0
      try handle.seek(toOffset: start)
      data = try handle.readToEnd() ?? Data()
    } catch {
      return nil
    }

    let boundedData: Data
    if startedMidFile,
      let firstNewline = data.firstIndex(of: 0x0A)
    {
      boundedData = data[data.index(after: firstNewline)...]
    } else {
      boundedData = data
    }
    guard let content = String(data: boundedData, encoding: .utf8) else { return nil }

    let lines = content.components(separatedBy: "\n")
    for line in lines.reversed() {
      if line.contains("RESTARTED:") || line.contains("ERROR DETECTED:") {
        return line
      }
    }
    return nil
  }

  static func truncateOversizedLogBeforeStart(path: String = logPath) throws {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? NSNumber,
      size.uint64Value > maximumLogBytes
    else {
      return
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
  }

  static func installLaunchAgent() throws {
    let execPath = ProcessInfo.processInfo.arguments[0]
    let resolvedPath = execPath.hasPrefix("/") ? execPath : "/usr/local/bin/imsg-plus"

    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>\(launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
              <string>\(resolvedPath)</string>
              <string>watchdog</string>
              <string>--run</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(logPath)</string>
          <key>StandardErrorPath</key>
          <string>\(logPath)</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
      </dict>
      </plist>
      """

    // Ensure LaunchAgents directory exists
    let launchAgentsDir = (launchAgentPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: launchAgentsDir,
      withIntermediateDirectories: true
    )

    try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
  }

  static func startLaunchAgent() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["load", launchAgentPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
  }

  static func stopLaunchAgent() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["unload", launchAgentPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
  }

  static func log(_ message: String, to output: FileHandle = .standardOutput) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)"
    output.write(Data((line + "\n").utf8))
  }
}
