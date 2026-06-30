import Foundation

enum HelperError: Error, CustomStringConvertible {
  case badArguments(String)
  case commandFailed(String)

  var description: String {
    switch self {
    case .badArguments(let message):
      return message
    case .commandFailed(let message):
      return message
    }
  }
}

struct MailScope {
  let mailbox: String
  let query: String
  let since: String
  let until: String
  let limit: Int

  var json: [String: Any] {
    var payload: [String: Any] = [:]
    if !mailbox.isEmpty { payload["mailbox"] = mailbox }
    if !query.isEmpty { payload["query"] = query }
    if !since.isEmpty { payload["since"] = since }
    if !until.isEmpty { payload["until"] = until }
    if limit > 0 { payload["limit"] = limit }
    return payload
  }
}

@main
struct LicoMailHelper {
  static let schemaVersion = "v0.0.1:lico-mail-helper-1"

  static func main() {
    do {
      let arguments = parseArguments(Array(CommandLine.arguments.dropFirst()))
      guard let command = arguments.positionals.first else {
        throw HelperError.badArguments("lico-mail-helper requires a command")
      }
      let payload: [String: Any]
      switch command {
      case "authorize":
        payload = try authorize()
      case "preview":
        payload = try preview(arguments: arguments)
      case "export":
        payload = try export(arguments: arguments)
      case "status":
        payload = try status(arguments: arguments)
      case "cancel":
        payload = try cancel(arguments: arguments)
      default:
        throw HelperError.badArguments("unsupported lico-mail-helper command: \(command)")
      }
      try printJson(payload)
    } catch {
      let payload: [String: Any] = [
        "ok": false,
        "schemaVersion": schemaVersion,
        "status": "failed",
        "error": String(describing: error),
      ]
      try? printJson(payload)
      Foundation.exit(1)
    }
  }

  static func authorize() throws -> [String: Any] {
    let output = try runAppleScript("""
with timeout of 30 seconds
  tell application "Mail"
    set accountCount to count of accounts
    set inboxMessageCount to count of messages of inbox
    return "accountCount=" & (accountCount as text) & linefeed & "inboxMessageCount=" & (inboxMessageCount as text)
  end tell
end timeout
""")
    let values = parseKeyValueLines(output)
    return [
      "ok": true,
      "schemaVersion": schemaVersion,
      "status": "authorized",
      "authorized": true,
      "accountCount": intValue(values["accountCount"]),
      "inboxMessageCount": intValue(values["inboxMessageCount"]),
    ]
  }

  static func preview(arguments: ParsedArguments) throws -> [String: Any] {
    let scope = try explicitScope(arguments: arguments, defaultLimit: 100)
    let stats = try runScopedMailScript(scope: scope, outputDirectory: nil)
    return [
      "ok": true,
      "schemaVersion": schemaVersion,
      "status": "preview_ready",
      "requiresExplicitScope": true,
      "scope": scope.json,
      "stats": stats,
    ]
  }

  static func export(arguments: ParsedArguments) throws -> [String: Any] {
    let scope = try explicitScope(arguments: arguments, defaultLimit: 25)
    let outputDirectory = try requiredPath(arguments, keys: ["output", "outputDirectory"])
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true)
    let stats = try runScopedMailScript(
      scope: scope,
      outputDirectory: outputDirectory)
    let files = try exportedFiles(in: outputDirectory)
    return [
      "ok": true,
      "schemaVersion": schemaVersion,
      "status": files.isEmpty ? "no_matches" : "exported",
      "requiresExplicitScope": true,
      "scope": scope.json,
      "outputDirectory": outputDirectory.path,
      "manifestPath": outputDirectory.appendingPathComponent("manifest.tsv").path,
      "exportedCount": files.count,
      "files": files,
      "stats": stats,
    ]
  }

  static func status(arguments: ParsedArguments) throws -> [String: Any] {
    let outputDirectory = pathValue(arguments, keys: ["output", "outputDirectory"])
    let files = try outputDirectory.map(exportedFiles(in:)) ?? []
    return [
      "ok": true,
      "schemaVersion": schemaVersion,
      "status": "ready",
      "outputDirectory": outputDirectory?.path ?? "",
      "exportedCount": files.count,
      "files": files,
    ]
  }

  static func cancel(arguments: ParsedArguments) throws -> [String: Any] {
    let outputDirectory = try requiredPath(arguments, keys: ["output", "outputDirectory"])
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true)
    let cancelFile = outputDirectory.appendingPathComponent("control.cancel")
    try "cancelled\n".write(to: cancelFile, atomically: true, encoding: .utf8)
    return [
      "ok": true,
      "schemaVersion": schemaVersion,
      "status": "cancelled",
      "cancelFile": cancelFile.path,
    ]
  }

  static func explicitScope(arguments: ParsedArguments, defaultLimit: Int) throws -> MailScope {
    let mailbox = stringValue(arguments, keys: ["mailbox"])
    let query = stringValue(arguments, keys: ["query", "q"])
    let since = stringValue(arguments, keys: ["since", "from"])
    let until = stringValue(arguments, keys: ["until", "to"])
    if mailbox.isEmpty && query.isEmpty && since.isEmpty && until.isEmpty {
      throw HelperError.badArguments(
        "mail helper requires explicit scope: --mailbox, --query, --since, or --until")
    }
    if since.isEmpty && until.isEmpty && query.isEmpty {
      throw HelperError.badArguments(
        "mail helper scope must include --since/--until or --query; mailbox-only imports are rejected")
    }
    let limit = intValue(stringValue(arguments, keys: ["limit"]), fallback: defaultLimit)
    return MailScope(
      mailbox: mailbox,
      query: query,
      since: since,
      until: until,
      limit: max(0, limit))
  }

  static func runScopedMailScript(
    scope: MailScope,
    outputDirectory: URL?
  ) throws -> [String: Any] {
    let exportMode = outputDirectory != nil
    let outputPath = outputDirectory?.path ?? ""
    let manifestPath = outputDirectory?.appendingPathComponent("manifest.tsv").path ?? ""
    if exportMode {
      try "fileName\tmessageId\tdateReceived\n".write(
        to: outputDirectory!.appendingPathComponent("manifest.tsv"),
        atomically: true,
        encoding: .utf8)
    }
    let script = scopedAppleScript(
      scope: scope,
      exportMode: exportMode,
      outputPath: outputPath,
      manifestPath: manifestPath)
    let output = try runAppleScript(script)
    let values = parseKeyValueLines(output)
    return [
      "mode": exportMode ? "export" : "preview",
      "accountCount": intValue(values["accountCount"]),
      "mailbox": scope.mailbox,
      "scannedCount": intValue(values["scannedCount"]),
      "matchedCount": intValue(values["matchedCount"]),
      "exportedCount": intValue(values["exportedCount"]),
      "limit": scope.limit,
      "truncatedByLimit": values["truncatedByLimit"] == "true",
    ]
  }

  static func scopedAppleScript(
    scope: MailScope,
    exportMode: Bool,
    outputPath: String,
    manifestPath: String
  ) -> String {
    let sinceSetup = dateSetup(variable: "sinceDate", raw: scope.since, endOfDay: false)
    let untilSetup = dateSetup(variable: "untilDate", raw: scope.until, endOfDay: true)
    return """
property mailboxName : \(appleScriptString(scope.mailbox))
property queryText : \(appleScriptString(scope.query))
property exportMode : \(exportMode ? "true" : "false")
property exportLimit : \(scope.limit)
property outputRootPath : \(appleScriptString(outputPath))
property manifestFilePath : \(appleScriptString(manifestPath))
property hasSinceDate : \(!scope.since.isEmpty ? "true" : "false")
property hasUntilDate : \(!scope.until.isEmpty ? "true" : "false")
property scannedCount : 0
property matchedCount : 0
property exportedCount : 0
property truncatedByLimit : false
property accountCount : 0
property sinceDate : missing value
property untilDate : missing value

\(sinceSetup)
\(untilSetup)

with timeout of 120 seconds
  tell application "Mail"
    set accountCount to count of accounts
    set messageRefs to my targetMessages()
    repeat with messageRef in messageRefs
      set scannedCount to scannedCount + 1
      if my messageMatches(messageRef) then
        set matchedCount to matchedCount + 1
        if exportMode then my exportMessage(messageRef, matchedCount)
        if exportLimit > 0 and matchedCount >= exportLimit then
          set truncatedByLimit to true
          exit repeat
        end if
      end if
    end repeat
  end tell
end timeout

return "accountCount=" & (accountCount as text) & linefeed & "scannedCount=" & (scannedCount as text) & linefeed & "matchedCount=" & (matchedCount as text) & linefeed & "exportedCount=" & (exportedCount as text) & linefeed & "truncatedByLimit=" & (truncatedByLimit as text)

on targetMessages()
  tell application "Mail"
    if mailboxName is "" or mailboxName is "Inbox" or mailboxName is "INBOX" then
      return messages of inbox
    end if
    set collectedMessages to {}
    try
      set namedMailboxes to mailboxes whose name is mailboxName
      repeat with mailboxRef in namedMailboxes
        set collectedMessages to collectedMessages & (messages of mailboxRef)
      end repeat
    end try
    return collectedMessages
  end tell
end targetMessages

on messageMatches(messageRef)
  tell application "Mail"
    if hasSinceDate then
      try
        if date received of messageRef < sinceDate then return false
      on error
        return false
      end try
    end if
    if hasUntilDate then
      try
        if date received of messageRef > untilDate then return false
      on error
        return false
      end try
    end if
    if queryText is not "" then
      set haystack to ""
      try
        set haystack to haystack & (subject of messageRef as text)
      end try
      try
        set haystack to haystack & " " & (sender of messageRef as text)
      end try
      ignoring case
        if haystack does not contain queryText then return false
      end ignoring
    end if
  end tell
  return true
end messageMatches

on exportMessage(messageRef, exportIndex)
  set fileName to "message-" & my paddedCounter(exportIndex) & ".eml"
  set targetPath to outputRootPath & "/" & fileName
  set rawSource to ""
  set messageIdText to ""
  set receivedText to ""
  tell application "Mail"
    try
      set rawSource to source of messageRef as text
    end try
    try
      set messageIdText to message id of messageRef as text
    end try
    try
      set receivedText to date received of messageRef as text
    end try
  end tell
  if rawSource is "" then error "message source is empty"
  my writeText(rawSource, targetPath)
  my appendText(fileName & tab & my sanitizeText(messageIdText) & tab & my sanitizeText(receivedText) & linefeed, manifestFilePath)
  set exportedCount to exportedCount + 1
end exportMessage

on paddedCounter(rawNumber)
  set rawText to rawNumber as text
  repeat while length of rawText < 6
    set rawText to "0" & rawText
  end repeat
  return rawText
end paddedCounter

on sanitizeText(rawText)
  set textValue to rawText as text
  set textValue to my replaceText(textValue, tab, " ")
  set textValue to my replaceText(textValue, linefeed, " ")
  set textValue to my replaceText(textValue, return, " ")
  return textValue
end sanitizeText

on replaceText(sourceText, searchText, replacementText)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to searchText
  set textItems to every text item of sourceText
  set AppleScript's text item delimiters to replacementText
  set replacedText to textItems as text
  set AppleScript's text item delimiters to previousDelimiters
  return replacedText
end replaceText

on writeText(rawText, targetPath)
  set fileHandle to missing value
  try
    set targetFile to POSIX file targetPath
    set fileHandle to open for access targetFile with write permission
    set eof of fileHandle to 0
    write rawText to fileHandle as «class utf8»
    close access fileHandle
  on error errorMessage number errorNumber
    try
      if fileHandle is not missing value then close access fileHandle
    end try
    error errorMessage number errorNumber
  end try
end writeText

on appendText(rawText, targetPath)
  set fileHandle to missing value
  try
    set targetFile to POSIX file targetPath
    set fileHandle to open for access targetFile with write permission
    write rawText to fileHandle starting at eof as «class utf8»
    close access fileHandle
  on error errorMessage number errorNumber
    try
      if fileHandle is not missing value then close access fileHandle
    end try
    error errorMessage number errorNumber
  end try
end appendText
"""
  }

  static func dateSetup(variable: String, raw: String, endOfDay: Bool) -> String {
    guard let parts = dateParts(raw) else {
      return ""
    }
    let monthName = [
      "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December",
    ][parts.month - 1]
    return """
set \(variable) to current date
set year of \(variable) to \(parts.year)
set month of \(variable) to \(monthName)
set day of \(variable) to \(parts.day)
set hours of \(variable) to \(endOfDay ? 23 : 0)
set minutes of \(variable) to \(endOfDay ? 59 : 0)
set seconds of \(variable) to \(endOfDay ? 59 : 0)
"""
  }

  static func dateParts(_ raw: String) -> (year: Int, month: Int, day: Int)? {
    let prefix = String(raw.prefix(10))
    let pieces = prefix.split(separator: "-").compactMap { Int($0) }
    guard pieces.count == 3,
      (1...12).contains(pieces[1]),
      (1...31).contains(pieces[2])
    else {
      return nil
    }
    return (pieces[0], pieces[1], pieces[2])
  }

  static func runAppleScript(_ script: String) throws -> String {
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("lico-mail-helper-\(UUID().uuidString).applescript")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [scriptURL.path]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    let error = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      throw HelperError.commandFailed(
        error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "osascript exited with \(process.terminationStatus)"
          : error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
  }

  static func exportedFiles(in directory: URL) throws -> [[String: Any]] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "eml" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { file in
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return [
          "name": file.lastPathComponent,
          "path": file.path,
          "byteSize": size,
        ]
      }
  }

  static func appleScriptString(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\":
        escaped += "\\\\"
      case "\"":
        escaped += "\\\""
      case "\n", "\r", "\t":
        escaped += " "
      default:
        escaped.unicodeScalars.append(scalar)
      }
    }
    return "\"\(escaped)\""
  }

  static func parseKeyValueLines(_ output: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      guard let separator = line.firstIndex(of: "=") else {
        continue
      }
      let key = String(line[..<separator])
      let value = String(line[line.index(after: separator)...])
      values[key] = value
    }
    return values
  }

  static func printJson(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: payload,
      options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  static func intValue(_ raw: String?, fallback: Int = 0) -> Int {
    Int((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
  }

  static func parseArguments(_ args: [String]) -> ParsedArguments {
    var values: [String: String] = [:]
    var positionals: [String] = []
    var index = 0
    while index < args.count {
      let arg = args[index]
      if arg.hasPrefix("--") {
        let raw = String(arg.dropFirst(2))
        if let equal = raw.firstIndex(of: "=") {
          values[String(raw[..<equal])] = String(raw[raw.index(after: equal)...])
        } else if index + 1 < args.count && !args[index + 1].hasPrefix("--") {
          values[raw] = args[index + 1]
          index += 1
        } else {
          values[raw] = "true"
        }
      } else {
        positionals.append(arg)
      }
      index += 1
    }
    return ParsedArguments(positionals: positionals, values: values)
  }

  static func stringValue(_ arguments: ParsedArguments, keys: [String]) -> String {
    for key in keys {
      if let value = arguments.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      {
        return value
      }
    }
    return ""
  }

  static func pathValue(_ arguments: ParsedArguments, keys: [String]) -> URL? {
    let raw = stringValue(arguments, keys: keys)
    return raw.isEmpty ? nil : URL(fileURLWithPath: raw)
  }

  static func requiredPath(_ arguments: ParsedArguments, keys: [String]) throws -> URL {
    guard let value = pathValue(arguments, keys: keys) else {
      throw HelperError.badArguments("missing path argument: --\(keys[0])")
    }
    return value
  }
}

struct ParsedArguments {
  let positionals: [String]
  let values: [String: String]
}
