import Cocoa
import CryptoKit
#if canImport(FlutterMacOS)
import FlutterMacOS
#endif

final class MacOSMailImporter {
#if canImport(FlutterMacOS)
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "lico/macos_mail_importer",
      binaryMessenger: controller.engine.binaryMessenger)
    let importer = MacOSMailImporter(channel: channel)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "exportAllMessages":
        importer.handleExportAllMessages(call: call, result: result)
      case "requestAuthorization":
        importer.handleRequestAuthorization(result: result)
      case "pauseExport":
        importer.handlePauseExport(result: result)
      case "resumeExport":
        importer.handleResumeExport(result: result)
      case "cancelExport":
        importer.handleCancelExport(result: result)
      case "getMailIndexStats":
        importer.handleGetMailIndexStats(call: call, result: result)
      case "rebuildMailIndex":
        importer.handleRebuildMailIndex(call: call, result: result)
      case "searchMailIndex":
        importer.handleSearchMailIndex(call: call, result: result)
      case "openMailIndexItem":
        importer.handleOpenMailIndexItem(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
#endif

  private let queue = DispatchQueue(
    label: "lico.macos_mail_importer",
    qos: .userInitiated)
  private let stateQueue = DispatchQueue(
    label: "lico.macos_mail_importer.state")
#if canImport(FlutterMacOS)
  private let channel: FlutterMethodChannel
#endif
  private var activePauseFile: URL?
  private var activeCancelFile: URL?

#if canImport(FlutterMacOS)
  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }
#else
  init() {}
#endif

#if canImport(FlutterMacOS)
  private func mailImportBaseDirectory(from call: FlutterMethodCall) throws -> URL {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let rawDirectory = (arguments["mailWorkspaceDirectory"] as? String) ??
      (arguments["exportBaseDirectory"] as? String)
    guard
      let rawDirectory,
      !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MacOSMailImporterError.badArguments("缺少 Mail.app 工作空间目录。")
    }
    return URL(fileURLWithPath: rawDirectory)
  }

  private func handleGetMailIndexStats(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    do {
      let baseDirectory = try mailImportBaseDirectory(from: call)
      result(
        MailIndexStore(
          baseDirectory: baseDirectory.appendingPathComponent(
            "index",
            isDirectory: true),
          downloadsDirectory: baseDirectory.appendingPathComponent(
            "downloads",
            isDirectory: true),
          manifestFile: baseDirectory.appendingPathComponent(
            "dedupe-manifest.tsv")
        ).statsPayload())
    } catch {
      result(
        FlutterError(
          code: "MAIL_INDEX_STATS_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleSearchMailIndex(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    do {
      let baseDirectory = try mailImportBaseDirectory(from: call)
      let arguments = call.arguments as? [String: Any] ?? [:]
      let query = arguments["query"] as? String ?? ""
      let filters = arguments["filters"] as? [String: Any] ?? [:]
      let limit = max(1, min(arguments["limit"] as? Int ?? 50, 200))
      let offset = max(0, arguments["offset"] as? Int ?? 0)
      result(
        MailIndexStore(
          baseDirectory: baseDirectory.appendingPathComponent(
            "index",
            isDirectory: true),
          downloadsDirectory: baseDirectory.appendingPathComponent(
            "downloads",
            isDirectory: true),
          manifestFile: baseDirectory.appendingPathComponent(
            "dedupe-manifest.tsv")
        ).searchPayload(
          query: query,
          filters: filters,
          limit: limit,
          offset: offset))
    } catch {
      result(
        FlutterError(
          code: "MAIL_INDEX_SEARCH_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleRebuildMailIndex(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    queue.async {
      do {
        let baseDirectory = try self.mailImportBaseDirectory(from: call)
        let payload = MailIndexStore(
          baseDirectory: baseDirectory.appendingPathComponent(
            "index",
            isDirectory: true),
          downloadsDirectory: baseDirectory.appendingPathComponent(
            "downloads",
            isDirectory: true),
          manifestFile: baseDirectory.appendingPathComponent(
            "dedupe-manifest.tsv")
        ).rebuildPayload()
        DispatchQueue.main.async {
          result(payload)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "MAIL_INDEX_REBUILD_FAILED",
              message: String(describing: error),
              details: nil))
        }
      }
    }
  }

  private func handleOpenMailIndexItem(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    do {
      let baseDirectory = try mailImportBaseDirectory(from: call)
      let arguments = call.arguments as? [String: Any] ?? [:]
      let store = MailIndexStore(
        baseDirectory: baseDirectory.appendingPathComponent(
          "index",
          isDirectory: true),
        downloadsDirectory: baseDirectory.appendingPathComponent(
          "downloads",
          isDirectory: true),
        manifestFile: baseDirectory.appendingPathComponent(
          "dedupe-manifest.tsv"))
      guard
        let payload = store.openPayload(
          docId: arguments["docId"] as? Int,
          messageKey: arguments["messageKey"] as? String)
      else {
        throw MacOSMailImporterError.badArguments("找不到索引邮件。")
      }
      result(payload)
    } catch {
      result(
        FlutterError(
          code: "MAIL_INDEX_OPEN_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleRequestAuthorization(result: @escaping FlutterResult) {
    queue.async {
      do {
        let payload = try Self.requestAuthorization()
        DispatchQueue.main.async {
          result(payload)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "MAIL_AUTHORIZATION_FAILED",
              message: String(describing: error),
              details: nil))
        }
      }
    }
  }

  private func handlePauseExport(result: @escaping FlutterResult) {
    guard let pauseFile = currentPauseFile() else {
      result(
        FlutterError(
          code: "MAIL_IMPORT_NOT_RUNNING",
          message: "当前没有正在运行的 Mail.app 导入任务。",
          details: nil))
      return
    }

    do {
      try "paused".write(to: pauseFile, atomically: true, encoding: .utf8)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "MAIL_IMPORT_PAUSE_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleResumeExport(result: @escaping FlutterResult) {
    guard let pauseFile = currentPauseFile() else {
      result(
        FlutterError(
          code: "MAIL_IMPORT_NOT_RUNNING",
          message: "当前没有正在运行的 Mail.app 导入任务。",
          details: nil))
      return
    }

    do {
      if FileManager.default.fileExists(atPath: pauseFile.path) {
        try FileManager.default.removeItem(at: pauseFile)
      }
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "MAIL_IMPORT_RESUME_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleCancelExport(result: @escaping FlutterResult) {
    guard let cancelFile = currentCancelFile() else {
      result(nil)
      return
    }

    do {
      try "cancelled".write(to: cancelFile, atomically: true, encoding: .utf8)
      if let pauseFile = currentPauseFile(),
        FileManager.default.fileExists(atPath: pauseFile.path)
      {
        try? FileManager.default.removeItem(at: pauseFile)
      }
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "MAIL_IMPORT_CANCEL_FAILED",
          message: String(describing: error),
          details: nil))
    }
  }

  private func handleExportAllMessages(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let rawDirectory = (arguments["mailWorkspaceDirectory"] as? String) ??
        (arguments["exportBaseDirectory"] as? String),
      !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      result(
        FlutterError(
          code: "MAIL_IMPORT_BAD_ARGUMENTS",
          message: "缺少 Mail.app 工作空间目录。",
          details: nil))
      return
    }

    queue.async {
      do {
        let payload = try self.exportAllMessages(
          mailWorkspaceDirectory: rawDirectory)
        DispatchQueue.main.async {
          result(payload)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "MAIL_IMPORT_FAILED",
              message: String(describing: error),
              details: nil))
        }
      }
    }
  }
#endif

  private func setCurrentPauseFile(_ pauseFile: URL?) {
    stateQueue.sync {
      activePauseFile = pauseFile
    }
  }

  private func setCurrentCancelFile(_ cancelFile: URL?) {
    stateQueue.sync {
      activeCancelFile = cancelFile
    }
  }

  private func currentPauseFile() -> URL? {
    stateQueue.sync {
      activePauseFile
    }
  }

  private func currentCancelFile() -> URL? {
    stateQueue.sync {
      activeCancelFile
    }
  }

  private static func requestAuthorization() throws -> [String: Any] {
    try ensureMailIsRunning()

    let scriptSource = """
with timeout of 30 seconds
  tell application "Mail"
    set accountCount to count of accounts
  end tell
end timeout
return accountCount as text
"""
    return [
      "authorized": true,
      "accountCount": Int(try runAppleScript(scriptSource)) ?? 0,
    ]
  }

  private func exportAllMessages(
    mailWorkspaceDirectory: String
  ) throws -> [String: Any] {
    let fileManager = FileManager.default
    let baseDirectory = URL(fileURLWithPath: mailWorkspaceDirectory)
    let exportDirectory = baseDirectory.appendingPathComponent(
      "downloads",
      isDirectory: true)
    let indexDirectory = baseDirectory.appendingPathComponent(
      "index",
      isDirectory: true)
    let tempDirectory = baseDirectory.appendingPathComponent(
      "tmp",
      isDirectory: true)
    let sourceTempDirectory = tempDirectory.appendingPathComponent(
      "sources",
      isDirectory: true)
    try fileManager.createDirectory(
      at: baseDirectory,
      withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: exportDirectory,
      withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: indexDirectory,
      withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: tempDirectory,
      withIntermediateDirectories: true)

    do {
      try Self.ensureMailIsRunning()
    } catch {
      try? Self.writeDiagnostics(
        [
          "workspaceDirectory": baseDirectory.path,
          "downloadsDirectory": exportDirectory.path,
          "tmpDirectory": tempDirectory.path,
          "launchError": String(describing: error),
        ],
        to: tempDirectory)
      throw error
    }

    let mailApplicationState = Self.describeMailApplicationState()
    let progressFile = tempDirectory.appendingPathComponent("progress.tsv")
    let manifestFile = tempDirectory.appendingPathComponent("manifest.tsv")
    let indexEventsFile = tempDirectory.appendingPathComponent(
      "index-events.tsv")
    let dedupeRequestsFile = tempDirectory.appendingPathComponent(
      "dedupe-requests.tsv")
    let dedupeResultsDirectory = tempDirectory.appendingPathComponent(
      "dedupe-results",
      isDirectory: true)
    let dedupeManifestFile = baseDirectory.appendingPathComponent(
      "dedupe-manifest.tsv")
    let pauseFile = tempDirectory.appendingPathComponent("control.pause")
    let cancelFile = tempDirectory.appendingPathComponent("control.cancel")
    try Data().write(to: progressFile, options: [.atomic])
    try Data().write(to: manifestFile, options: [.atomic])
    try Data().write(to: indexEventsFile, options: [.atomic])
    try Data().write(to: dedupeRequestsFile, options: [.atomic])
    try? fileManager.removeItem(at: dedupeResultsDirectory)
    try? fileManager.removeItem(at: sourceTempDirectory)
    try fileManager.createDirectory(
      at: dedupeResultsDirectory,
      withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: sourceTempDirectory,
      withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: dedupeManifestFile.path) {
      fileManager.createFile(atPath: dedupeManifestFile.path, contents: nil)
    }
    try? FileManager.default.removeItem(at: pauseFile)
    try? FileManager.default.removeItem(at: cancelFile)
    try? Self.writeDiagnostics(
      [
        "workspaceDirectory": baseDirectory.path,
        "downloadsDirectory": exportDirectory.path,
        "indexDirectory": indexDirectory.path,
        "tmpDirectory": tempDirectory.path,
        "mailApplicationState": mailApplicationState,
        "status": "started",
      ],
      to: tempDirectory)
    setCurrentPauseFile(pauseFile)
    setCurrentCancelFile(cancelFile)
#if canImport(FlutterMacOS)
    let progressMonitor = MailImportProgressMonitor(
      progressFile: progressFile,
      exportDirectory: exportDirectory,
      channel: channel)
#else
    let progressMonitor = MailImportProgressMonitor(
      progressFile: progressFile,
      exportDirectory: exportDirectory)
#endif
    let indexCoordinator = MailIndexCoordinator(
      indexDirectory: indexDirectory,
      downloadsDirectory: exportDirectory,
      manifestFile: dedupeManifestFile,
      sourceEventsFile: indexEventsFile)
    let dedupeCoordinator = MailExportDeduperCoordinator(
      requestsFile: dedupeRequestsFile,
      resultsDirectory: dedupeResultsDirectory,
      manifestFile: dedupeManifestFile)
    progressMonitor.send(
      [
        "kind": "started",
        "sequence": 0,
        "totalCount": 0,
        "exportedCount": 0,
        "failedCount": 0,
        "skippedCount": 0,
        "title": "",
        "detail": "",
        "exportDirectory": exportDirectory.path,
      ])
    progressMonitor.start()
    dedupeCoordinator.start()
    indexCoordinator.start()
    defer {
      progressMonitor.stop()
      dedupeCoordinator.stopAndFlush()
      indexCoordinator.stopAndFlush()
      try? FileManager.default.removeItem(at: pauseFile)
      try? FileManager.default.removeItem(at: cancelFile)
      setCurrentPauseFile(nil)
      setCurrentCancelFile(nil)
    }

    let scriptSource = Self.exportScript(
      exportDirectory: exportDirectory.path,
      sourceTempDirectory: sourceTempDirectory.path,
      progressFilePath: progressFile.path,
      manifestFilePath: manifestFile.path,
      indexEventsFilePath: indexEventsFile.path,
      dedupeRequestsFilePath: dedupeRequestsFile.path,
      dedupeResultsDirectoryPath: dedupeResultsDirectory.path,
      pauseFilePath: pauseFile.path,
      cancelFilePath: cancelFile.path)
    let rawCounts: String
    do {
      rawCounts = try Self.runAppleScript(scriptSource)
    } catch {
      try? Self.writeDiagnostics(
        [
          "workspaceDirectory": baseDirectory.path,
          "downloadsDirectory": exportDirectory.path,
          "tmpDirectory": tempDirectory.path,
          "mailApplicationState": mailApplicationState,
          "scriptError": String(describing: error),
        ],
        to: tempDirectory)
      throw error
    }

    let counts = Self.parseCounts(rawCounts)
    let fileCount = Self.countEmlFiles(in: exportDirectory)
    let payload: [String: Any] = [
      "workspaceDirectory": baseDirectory.path,
      "exportDirectory": exportDirectory.path,
      "tmpDirectory": tempDirectory.path,
      "exportedCount": counts.exported,
      "failedCount": counts.failed,
      "skippedCount": counts.skipped,
      "fileCount": fileCount,
      "scannedAccountCount": counts.accounts,
      "scannedMailboxCount": counts.mailboxes,
      "scannedMessageCount": counts.messages,
      "lastError": counts.lastError,
    ]
    try? Self.writeDiagnostics(payload, to: tempDirectory)
    return payload
  }

  private static func exportScript(
    exportDirectory: String,
    sourceTempDirectory: String,
    progressFilePath: String,
    manifestFilePath: String,
    indexEventsFilePath: String,
    dedupeRequestsFilePath: String,
    dedupeResultsDirectoryPath: String,
    pauseFilePath: String,
    cancelFilePath: String
  ) -> String {
    let normalizedDirectory = exportDirectory.hasSuffix("/")
      ? exportDirectory
      : "\(exportDirectory)/"
    let normalizedSourceTempDirectory = sourceTempDirectory.hasSuffix("/")
      ? sourceTempDirectory
      : "\(sourceTempDirectory)/"
    let exportRootPath = appleScriptStringLiteral(normalizedDirectory)
    let sourceTempRootPath = appleScriptStringLiteral(normalizedSourceTempDirectory)
    let progressPath = appleScriptStringLiteral(progressFilePath)
    let manifestPath = appleScriptStringLiteral(manifestFilePath)
    let indexEventsPath = appleScriptStringLiteral(indexEventsFilePath)
    let dedupeRequestsPath = appleScriptStringLiteral(dedupeRequestsFilePath)
    let dedupeResultsPath = appleScriptStringLiteral(dedupeResultsDirectoryPath)
    let pausePath = appleScriptStringLiteral(pauseFilePath)
    let cancelPath = appleScriptStringLiteral(cancelFilePath)

    return """
property scannedAccountCount : 0
property scannedMailboxCount : 0
property scannedMessageCount : 0
property exportedCount : 0
property failedCount : 0
property skippedCount : 0
property skipMailboxNames : {"Conflicts", "Local Failures", "Server Failures", "Sync Issues", "All Mail", "Starred", "Important", "冲突", "本地故障", "服务器故障", "同步问题", "所有邮件", "已加星标", "重要"}
property messageCounter : 0
property totalMessageCount : 0
property lastError : ""
property progressFilePath : ""
property manifestFilePath : ""
property indexEventsFilePath : ""
property dedupeRequestsFilePath : ""
property dedupeResultsDirectoryPath : ""
property sourceTempRootPath : ""
property pauseFilePath : ""
property cancelFilePath : ""

set scannedAccountCount to 0
set scannedMailboxCount to 0
set scannedMessageCount to 0
set exportedCount to 0
set failedCount to 0
set skippedCount to 0
set messageCounter to 0
set totalMessageCount to 0
set lastError to ""
set exportRootPath to \(exportRootPath)
set sourceTempRootPath to \(sourceTempRootPath)
set progressFilePath to \(progressPath)
set manifestFilePath to \(manifestPath)
set indexEventsFilePath to \(indexEventsPath)
set dedupeRequestsFilePath to \(dedupeRequestsPath)
set dedupeResultsDirectoryPath to \(dedupeResultsPath)
set pauseFilePath to \(pausePath)
set cancelFilePath to \(cancelPath)

with timeout of 86400 seconds
  tell application "Mail"
    my writeProgressEvent("scanning", 0, exportedCount, failedCount, skippedCount, "", "准备扫描邮箱")
    set accountRefs to {}
    try
      with timeout of 10 seconds
        set accountRefs to accounts
      end timeout
      if accountRefs is missing value then set accountRefs to {}
    on error errorMessage number errorNumber
      set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      set accountRefs to {}
    end try
    repeat with accountRef in accountRefs
      my checkIfCancelled()
      set scannedAccountCount to scannedAccountCount + 1
      set scanAccountName to ""
      try
        set scanAccountName to name of accountRef as text
      end try
      if scanAccountName is "" then set scanAccountName to "Account"
      my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, scanAccountName, "扫描账号")
      set accountMailboxes to {}
      try
        with timeout of 10 seconds
          set accountMailboxes to mailboxes of accountRef
        end timeout
        if accountMailboxes is missing value then set accountMailboxes to {}
      on error errorMessage number errorNumber
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try

      repeat with mailboxRef in accountMailboxes
        try
          my checkIfCancelled()
          set scannedMailboxCount to scannedMailboxCount + 1
          my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, my mailboxNameFor(mailboxRef), "已发现邮箱")
        on error errorMessage number errorNumber
          if my isCancelRequested() then error "Mail.app 导入已取消"
          set failedCount to failedCount + 1
          set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
        end try
      end repeat
    end repeat

    set rootMailboxes to {}
    try
      my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, "Local", "扫描本机邮箱")
      with timeout of 10 seconds
        set rootMailboxes to mailboxes
      end timeout
      if rootMailboxes is missing value then set rootMailboxes to {}
    on error errorMessage number errorNumber
      set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
    end try

    repeat with mailboxRef in rootMailboxes
      try
        my checkIfCancelled()
        set scannedMailboxCount to scannedMailboxCount + 1
        my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, my mailboxNameFor(mailboxRef), "已发现本机邮箱")
      on error errorMessage number errorNumber
        if my isCancelRequested() then error "Mail.app 导入已取消"
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try
    end repeat

    set totalMessageCount to 0
    my writeProgressEvent("planned", 0, exportedCount, failedCount, skippedCount, "", "")

    repeat with accountRef in accountRefs
      my checkIfCancelled()
      set accountName to ""
      try
        set accountName to name of accountRef as text
      end try
      if accountName is "" then set accountName to "Account"
      set accountMailboxes to {}
      try
        with timeout of 10 seconds
          set accountMailboxes to mailboxes of accountRef
        end timeout
        if accountMailboxes is missing value then set accountMailboxes to {}
      on error errorMessage number errorNumber
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try

      repeat with mailboxRef in accountMailboxes
        try
          my checkIfCancelled()
          my exportMailbox(mailboxRef, exportRootPath, accountName, my mailboxNameFor(mailboxRef))
        on error errorMessage number errorNumber
          if my isCancelRequested() then error "Mail.app 导入已取消"
          set failedCount to failedCount + 1
          set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
        end try
      end repeat
    end repeat

    repeat with mailboxRef in rootMailboxes
      try
        my checkIfCancelled()
        my exportMailbox(mailboxRef, exportRootPath, "Local", my mailboxNameFor(mailboxRef))
      on error errorMessage number errorNumber
        if my isCancelRequested() then error "Mail.app 导入已取消"
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try
    end repeat
  end tell
end timeout

my writeProgressEvent("completed", messageCounter, exportedCount, failedCount, skippedCount, "", "")
return (exportedCount as text) & "|" & (failedCount as text) & "|" & (skippedCount as text) & "|" & (scannedAccountCount as text) & "|" & (scannedMailboxCount as text) & "|" & (scannedMessageCount as text) & "|" & lastError

on countMailboxMessages(mailboxRef)
  tell application "Mail"
    my checkIfCancelled()
    set scannedMailboxCount to scannedMailboxCount + 1
    set scanMailboxName to ""
    try
      set scanMailboxName to name of mailboxRef as text
    end try
    if scanMailboxName is "" then set scanMailboxName to "Mailbox"
    my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, scanMailboxName, "扫描邮箱")
    if my shouldSkipMailbox(scanMailboxName) then
      set skippedCount to skippedCount + 1
      my writeProgressEvent("skipped", scannedMessageCount, exportedCount, failedCount, skippedCount, scanMailboxName, "跳过系统同步故障邮箱")
      return
    end if
    try
      with timeout of 10 seconds
        set scannedMessageCount to scannedMessageCount + (count of messages of mailboxRef)
      end timeout
      my writeProgressEvent("scanning", scannedMessageCount, exportedCount, failedCount, skippedCount, scanMailboxName, "已计数 " & (scannedMailboxCount as text) & " 个邮箱")
    on error errorMessage number errorNumber
      if my isCancelRequested() then error "Mail.app 导入已取消"
      set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
    end try

    set childMailboxes to {}
    try
      with timeout of 10 seconds
        set childMailboxes to mailboxes of mailboxRef
      end timeout
      if childMailboxes is missing value then set childMailboxes to {}
    on error errorMessage number errorNumber
      set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
    end try
    repeat with childMailboxRef in childMailboxes
      try
        my checkIfCancelled()
        my countMailboxMessages(childMailboxRef)
      on error errorMessage number errorNumber
        if my isCancelRequested() then error "Mail.app 导入已取消"
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try
    end repeat
  end tell
end countMailboxMessages

on exportMailbox(mailboxRef, exportRootPath, accountName, mailboxPath)
  tell application "Mail"
    set mailboxLabel to my mailboxNameFor(mailboxRef)
    if my shouldSkipMailbox(mailboxLabel) then
      set skippedCount to skippedCount + 1
      my writeProgressEvent("skipped", messageCounter, exportedCount, failedCount, skippedCount, mailboxPath, "跳过系统同步故障邮箱")
      return
    end if
    set mailboxReadFailures to 0
    set messageIndex to 1
    my writeProgressEvent("planned", messageCounter, exportedCount, failedCount, skippedCount, mailboxPath, "准备导出邮箱")
    repeat 1000000 times
      my waitIfPaused()
      my checkIfCancelled()
      set messageRef to missing value
      set shouldProcessMessage to true
      try
        with timeout of 10 seconds
          set messageRef to message messageIndex of mailboxRef
        end timeout
      on error errorMessage number errorNumber
        if my isMailboxExhausted(errorMessage, errorNumber) then exit repeat
        if my isCancelRequested() then error "Mail.app 导入已取消"
        set mailboxReadFailures to mailboxReadFailures + 1
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
        if mailboxReadFailures is greater than or equal to 3 then exit repeat
        set messageIndex to messageIndex + 1
        set shouldProcessMessage to false
      end try
      if shouldProcessMessage and messageRef is not missing value then
      set mailboxReadFailures to 0
      set messageCounter to messageCounter + 1
      set messageIndex to messageIndex + 1
      set messageSubject to ""
      try
        set messageSubject to subject of messageRef
      end try
      set messageKey to my messageKeyForMessage(messageRef, messageCounter)
      set senderText to my senderForMessage(messageRef)
      set toText to my recipientsForMessage(messageRef, "to")
      set ccText to my recipientsForMessage(messageRef, "cc")
      set dateSentText to my dateTextForMessage(messageRef, "sent")
      set dateReceivedText to my dateTextForMessage(messageRef, "received")
      set sourceTempPath to ""
      my writeManifestEntry(messageCounter, messageSubject)
      my writeDetailedProgressEvent("processing", messageCounter, exportedCount, failedCount, skippedCount, messageSubject, "", messageKey, accountName, mailboxPath, senderText, toText, ccText, dateSentText, dateReceivedText, "", "", "", "", "processing")

      try
        set fileName to my fileNameForMessage(messageSubject, messageKey, messageCounter)
        set targetPath to exportRootPath & fileName
        set fastDecision to my existingExportDecision(messageCounter, messageKey, targetPath)
        set fastDecisionKind to item 1 of fastDecision
        set fastResolvedPath to item 2 of fastDecision
        set fastSourceHashText to item 3 of fastDecision
        set fastSourceByteSizeText to item 4 of fastDecision
        if fastDecisionKind is "skip" then
          set skippedCount to skippedCount + 1
          my writeIndexEvent(messageCounter, messageKey, my fileNameFromPath(fastResolvedPath), accountName, mailboxPath, messageSubject, senderText, toText, ccText, dateSentText, dateReceivedText, "skipped", "", fastSourceHashText, fastSourceByteSizeText)
          my writeDetailedProgressEvent("skipped", messageCounter, exportedCount, failedCount, skippedCount, messageSubject, my fileNameFromPath(fastResolvedPath), messageKey, accountName, mailboxPath, senderText, toText, ccText, dateSentText, dateReceivedText, my fileNameFromPath(fastResolvedPath), fastSourceHashText, fastSourceByteSizeText, "", "skipped")
        else
          with timeout of 20 seconds
            set rawSource to source of messageRef
          end timeout
          if rawSource is missing value or rawSource is "" then error "message source is empty"

        set sourceTempPath to my temporarySourcePath(sourceTempRootPath, messageCounter)
        my writeRawSource(rawSource, sourceTempPath)
        set exportDecision to my exportTargetDecision(messageCounter, messageKey, targetPath, sourceTempPath)
        set decisionKind to item 1 of exportDecision
        set resolvedPath to item 2 of exportDecision
        set sourceHashText to item 3 of exportDecision
        set sourceByteSizeText to item 4 of exportDecision
        if decisionKind is "skip" then
          set skippedCount to skippedCount + 1
          my writeIndexEvent(messageCounter, messageKey, my fileNameFromPath(resolvedPath), accountName, mailboxPath, messageSubject, senderText, toText, ccText, dateSentText, dateReceivedText, "skipped", "", sourceHashText, sourceByteSizeText)
          my writeDetailedProgressEvent("skipped", messageCounter, exportedCount, failedCount, skippedCount, messageSubject, my fileNameFromPath(resolvedPath), messageKey, accountName, mailboxPath, senderText, toText, ccText, dateSentText, dateReceivedText, my fileNameFromPath(resolvedPath), sourceHashText, sourceByteSizeText, "", "skipped")
        else
          set exportedCount to exportedCount + 1
          my writeIndexEvent(messageCounter, messageKey, my fileNameFromPath(resolvedPath), accountName, mailboxPath, messageSubject, senderText, toText, ccText, dateSentText, dateReceivedText, "exported", "", sourceHashText, sourceByteSizeText)
          my writeDetailedProgressEvent("exported", messageCounter, exportedCount, failedCount, skippedCount, messageSubject, my fileNameFromPath(resolvedPath), messageKey, accountName, mailboxPath, senderText, toText, ccText, dateSentText, dateReceivedText, my fileNameFromPath(resolvedPath), sourceHashText, sourceByteSizeText, "", "exported")
        end if
        end if
      on error errorMessage number errorNumber
        if my isCancelRequested() then error "Mail.app 导入已取消"
        if sourceTempPath is not "" then my removeFileIfExists(sourceTempPath)
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
        my writeIndexEvent(messageCounter, messageKey, "", accountName, mailboxPath, messageSubject, senderText, toText, ccText, dateSentText, dateReceivedText, "failed", errorMessage, "", "")
        my writeDetailedProgressEvent("failed", messageCounter, exportedCount, failedCount, skippedCount, messageSubject, errorMessage, messageKey, accountName, mailboxPath, senderText, toText, ccText, dateSentText, dateReceivedText, "", "", "", errorMessage, "failed")
      end try
      end if
    end repeat

    set childMailboxes to {}
    try
      with timeout of 10 seconds
        set childMailboxes to mailboxes of mailboxRef
      end timeout
      if childMailboxes is missing value then set childMailboxes to {}
    on error errorMessage number errorNumber
      set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
    end try
    repeat with childMailboxRef in childMailboxes
      try
        my checkIfCancelled()
        set childMailboxPath to mailboxPath & "/" & my mailboxNameFor(childMailboxRef)
        my exportMailbox(childMailboxRef, exportRootPath, accountName, childMailboxPath)
      on error errorMessage number errorNumber
        if my isCancelRequested() then error "Mail.app 导入已取消"
        set failedCount to failedCount + 1
        set lastError to my sanitizeDiagnostic(errorMessage & " (" & errorNumber & ")")
      end try
    end repeat
  end tell
end exportMailbox

on isMailboxExhausted(errorMessage, errorNumber)
  if errorNumber is -1728 then return true
  set messageText to ""
  try
    set messageText to errorMessage as text
  end try
  if messageText contains "Can’t get message" then return true
  if messageText contains "Can't get message" then return true
  if messageText contains "无法获取 message" then return true
  if messageText contains "无法取得 message" then return true
  return false
end isMailboxExhausted

on writeRawSource(rawSource, targetPath)
  set fileHandle to missing value
  try
    set targetFile to POSIX file targetPath
    set fileHandle to open for access targetFile with write permission
    set eof of fileHandle to 0
    write rawSource to fileHandle as «class utf8»
    close access fileHandle
  on error errorMessage number errorNumber
    try
      if fileHandle is not missing value then close access fileHandle
    end try
    error errorMessage number errorNumber
  end try
end writeRawSource

on writeProgressEvent(eventName, counterValue, exportedValue, failedValue, skippedValue, subjectValue, detailValue)
  try
    set progressLine to eventName & tab & (counterValue as text) & tab & (totalMessageCount as text) & tab & (exportedValue as text) & tab & (failedValue as text) & tab & (skippedValue as text) & tab & my sanitizeProgressText(subjectValue) & tab & my sanitizeProgressText(detailValue) & linefeed
    my appendText(progressLine, progressFilePath)
  end try
end writeProgressEvent

on writeDetailedProgressEvent(eventName, counterValue, exportedValue, failedValue, skippedValue, subjectValue, detailValue, messageKey, accountName, mailboxPath, senderValue, toValue, ccValue, dateSentValue, dateReceivedValue, fileNameValue, sourceHashValue, sourceByteSizeValue, errorValue, statusValue)
  try
    set progressLine to eventName & tab & (counterValue as text) & tab & (totalMessageCount as text) & tab & (exportedValue as text) & tab & (failedValue as text) & tab & (skippedValue as text) & tab & my sanitizeIndexText(subjectValue) & tab & my sanitizeIndexText(detailValue) & tab & my sanitizeIndexText(messageKey) & tab & my sanitizeIndexText(accountName) & tab & my sanitizeIndexText(mailboxPath) & tab & my sanitizeIndexText(senderValue) & tab & my sanitizeIndexText(toValue) & tab & my sanitizeIndexText(ccValue) & tab & my sanitizeIndexText(dateSentValue) & tab & my sanitizeIndexText(dateReceivedValue) & tab & my sanitizeIndexText(fileNameValue) & tab & my sanitizeIndexText(sourceHashValue) & tab & my sanitizeIndexText(sourceByteSizeValue) & tab & my sanitizeIndexText(errorValue) & tab & my sanitizeIndexText(statusValue) & linefeed
    my appendText(progressLine, progressFilePath)
  end try
end writeDetailedProgressEvent

on writeManifestEntry(counterValue, subjectValue)
  try
    set manifestLine to (counterValue as text) & tab & my sanitizeProgressText(subjectValue) & linefeed
    my appendText(manifestLine, manifestFilePath)
  end try
end writeManifestEntry

on writeIndexEvent(counterValue, messageKey, fileName, accountName, mailboxPath, subjectValue, senderValue, toValue, ccValue, dateSentValue, dateReceivedValue, statusValue, errorValue, sourceHashValue, sourceByteSizeValue)
  try
    set eventLine to (counterValue as text) & tab & my sanitizeIndexText(messageKey) & tab & my sanitizeIndexText(fileName) & tab & my sanitizeIndexText(accountName) & tab & my sanitizeIndexText(mailboxPath) & tab & my sanitizeIndexText(subjectValue) & tab & my sanitizeIndexText(senderValue) & tab & my sanitizeIndexText(toValue) & tab & my sanitizeIndexText(ccValue) & tab & my sanitizeIndexText(dateSentValue) & tab & my sanitizeIndexText(dateReceivedValue) & tab & my sanitizeIndexText(statusValue) & tab & my sanitizeIndexText(errorValue) & tab & my sanitizeIndexText(sourceHashValue) & tab & my sanitizeIndexText(sourceByteSizeValue) & linefeed
    my appendText(eventLine, indexEventsFilePath)
  end try
end writeIndexEvent

on mailboxNameFor(mailboxRef)
  set mailboxName to ""
  tell application "Mail"
    try
      set mailboxName to name of mailboxRef as text
    end try
  end tell
  if mailboxName is "" then return "Mailbox"
  return my sanitizeProgressText(mailboxName)
end mailboxNameFor

on senderForMessage(messageRef)
  set senderText to ""
  tell application "Mail"
    try
      set senderText to sender of messageRef as text
    end try
  end tell
  return senderText
end senderForMessage

on shouldSkipMailbox(mailboxNameText)
  repeat with skipName in skipMailboxNames
    if mailboxNameText is (skipName as text) then return true
  end repeat
  return false
end shouldSkipMailbox

on recipientsForMessage(messageRef, recipientKind)
  set recipientTexts to {}
  tell application "Mail"
    set recipientRefs to {}
    try
      if recipientKind is "cc" then
        set recipientRefs to cc recipients of messageRef
      else
        set recipientRefs to to recipients of messageRef
      end if
      if recipientRefs is missing value then set recipientRefs to {}
    end try
    repeat with recipientRef in recipientRefs
      set recipientText to ""
      try
        set recipientText to address of recipientRef as text
      end try
      if recipientText is "" then
        try
          set recipientText to name of recipientRef as text
        end try
      end if
      if recipientText is not "" then set end of recipientTexts to recipientText
    end repeat
  end tell
  return my joinTextList(recipientTexts, ", ")
end recipientsForMessage

on dateTextForMessage(messageRef, dateKind)
  set dateText to ""
  tell application "Mail"
    try
      if dateKind is "sent" then
        set dateText to date sent of messageRef as text
      else
        set dateText to date received of messageRef as text
      end if
    end try
  end tell
  return dateText
end dateTextForMessage

on joinTextList(rawItems, separatorText)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to separatorText
  set joinedText to rawItems as text
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joinTextList

on waitIfPaused()
  set didPause to false
  repeat while my isPauseRequested()
    my checkIfCancelled()
    if didPause is false then
      my writeProgressEvent("paused", messageCounter, exportedCount, failedCount, skippedCount, "", "")
      set didPause to true
    end if
    delay 0.35
  end repeat
  my checkIfCancelled()
  if didPause then my writeProgressEvent("resumed", messageCounter, exportedCount, failedCount, skippedCount, "", "")
end waitIfPaused

on checkIfCancelled()
  if my isCancelRequested() then error "Mail.app 导入已取消"
end checkIfCancelled

on isPauseRequested()
  try
    do shell script "/bin/test -e " & quoted form of pauseFilePath
    return true
  on error
    return false
  end try
end isPauseRequested

on isCancelRequested()
  try
    do shell script "/bin/test -e " & quoted form of cancelFilePath
    return true
  on error
    return false
  end try
end isCancelRequested

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

on fileExists(targetPath)
  try
    do shell script "/bin/test -f " & quoted form of targetPath
    return true
  on error
    return false
  end try
end fileExists

on removeFileIfExists(targetPath)
  try
    do shell script "/bin/rm -f " & quoted form of targetPath
  end try
end removeFileIfExists

on readTextFile(targetPath)
  set targetFile to POSIX file targetPath
  return read targetFile as «class utf8»
end readTextFile

on temporarySourcePath(sourceTempRootPath, counterValue)
  return sourceTempRootPath & ".source-" & my paddedCounter(counterValue) & ".eml.tmp"
end temporarySourcePath

on existingExportDecision(counterValue, messageKey, targetPath)
  set requestLine to (counterValue as text) & tab & my sanitizeTsvText(messageKey) & tab & my sanitizeTsvText(targetPath) & tab & "-" & tab & "lookup" & linefeed
  my appendText(requestLine, dedupeRequestsFilePath)
  return my waitForExportDecision(counterValue)
end existingExportDecision

on exportTargetDecision(counterValue, messageKey, targetPath, sourceTempPath)
  set requestLine to (counterValue as text) & tab & my sanitizeTsvText(messageKey) & tab & my sanitizeTsvText(targetPath) & tab & my sanitizeTsvText(sourceTempPath) & tab & "verify" & linefeed
  my appendText(requestLine, dedupeRequestsFilePath)
  return my waitForExportDecision(counterValue)
end exportTargetDecision

on waitForExportDecision(counterValue)
  set resultPath to dedupeResultsDirectoryPath & "/" & my paddedCounter(counterValue) & ".tsv"
  set attemptsRemaining to 6000
  repeat while attemptsRemaining > 0
    my checkIfCancelled()
    if my fileExists(resultPath) then
      set resultLine to my readTextFile(resultPath)
      set resultParts to my splitTabLine(resultLine)
      if (count of resultParts) < 6 then error "Swift 邮件去重结果格式不完整"
      if item 2 of resultParts is "error" then error item 6 of resultParts
      return {item 2 of resultParts, item 3 of resultParts, item 4 of resultParts, item 5 of resultParts}
    end if
    delay 0.02
    set attemptsRemaining to attemptsRemaining - 1
  end repeat
  error "Swift 邮件去重超时"
end waitForExportDecision

on splitTabLine(rawText)
  set textValue to rawText as text
  set textValue to my replaceText(textValue, return, "")
  set textValue to my replaceText(textValue, linefeed, "")
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to tab
  set resultParts to text items of textValue
  set AppleScript's text item delimiters to previousDelimiters
  return resultParts
end splitTabLine

on fileNameFromPath(targetPath)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "/"
  set pathItems to text items of targetPath
  set AppleScript's text item delimiters to previousDelimiters
  if (count of pathItems) is 0 then return targetPath
  return item -1 of pathItems
end fileNameFromPath

on messageKeyForMessage(messageRef, counterValue)
  set keyText to ""
  tell application "Mail"
    try
      set rawMessageID to message id of messageRef
      if rawMessageID is not missing value then set keyText to rawMessageID as text
    end try
    if keyText is "" then
      try
        set keyText to (id of messageRef) as text
      end try
    end if
  end tell
  if keyText is "" then set keyText to my paddedCounter(counterValue)
  return keyText
end messageKeyForMessage

on fileNameForMessage(rawSubject, messageKey, counterValue)
  set subjectText to ""
  try
    if rawSubject is not missing value then set subjectText to rawSubject as text
  end try

  set subjectText to my sanitizeFileName(subjectText)
  if subjectText is "" then set subjectText to "无标题邮件"
  if (count characters of subjectText) > 56 then set subjectText to text 1 thru 56 of subjectText

  set keyText to my sanitizeFileName(messageKey)
  if keyText is "" then set keyText to my paddedCounter(counterValue)
  if (count characters of keyText) > 48 then set keyText to text 1 thru 48 of keyText

  return subjectText & " - " & keyText & ".eml"
end fileNameForMessage

on paddedCounter(counterValue)
  set counterText to counterValue as text
  repeat while (count characters of counterText) < 6
    set counterText to "0" & counterText
  end repeat
  return counterText
end paddedCounter

on sanitizeFileName(rawText)
  set textValue to rawText as text
  set invalidCharacters to {":", "/", (ASCII character 34), (ASCII character 92), "|", "?", "*", "<", ">", tab, return, linefeed}
  repeat with invalidCharacter in invalidCharacters
    set textValue to my replaceText(textValue, invalidCharacter as text, " ")
  end repeat

  set textValue to my trimFileName(textValue)
  if (count characters of textValue) > 72 then set textValue to text 1 thru 72 of textValue
  return my trimFileName(textValue)
end sanitizeFileName

on replaceText(rawText, searchText, replacementText)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to searchText
  set textParts to text items of rawText
  set AppleScript's text item delimiters to replacementText
  set replacedText to textParts as text
  set AppleScript's text item delimiters to previousDelimiters
  return replacedText
end replaceText

on trimFileName(rawText)
  set textValue to rawText as text
  repeat while textValue begins with " " or textValue begins with "."
    if (count characters of textValue) <= 1 then return ""
    set textValue to text 2 thru -1 of textValue
  end repeat
  repeat while textValue ends with " " or textValue ends with "."
    if (count characters of textValue) <= 1 then return ""
    set textValue to text 1 thru -2 of textValue
  end repeat
  return textValue
end trimFileName

on sanitizeTsvText(rawText)
  set textValue to ""
  try
    if rawText is not missing value then set textValue to rawText as text
  end try
  set textValue to my replaceText(textValue, tab, " ")
  set textValue to my replaceText(textValue, return, " ")
  set textValue to my replaceText(textValue, linefeed, " ")
  return textValue
end sanitizeTsvText

on sanitizeIndexText(rawText)
  set textValue to my sanitizeTsvText(rawText)
  if (count characters of textValue) > 2048 then set textValue to text 1 thru 2048 of textValue
  return textValue
end sanitizeIndexText

on sanitizeProgressText(rawText)
  set textValue to my sanitizeTsvText(rawText)
  if (count characters of textValue) > 120 then set textValue to text 1 thru 120 of textValue
  return textValue
end sanitizeProgressText

on sanitizeDiagnostic(rawText)
  set textValue to rawText as text
  set AppleScript's text item delimiters to "|"
  set textParts to text items of textValue
  set AppleScript's text item delimiters to "/"
  set textValue to textParts as text
  set AppleScript's text item delimiters to linefeed
  set textParts to text items of textValue
  set AppleScript's text item delimiters to " "
  set textValue to textParts as text
  set AppleScript's text item delimiters to ""
  if (count characters of textValue) > 280 then set textValue to text 1 thru 280 of textValue
  return textValue
end sanitizeDiagnostic
"""
  }

  private static func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  private static func parseCounts(_ rawValue: String) -> (
    exported: Int,
    failed: Int,
    skipped: Int,
    accounts: Int,
    mailboxes: Int,
    messages: Int,
    lastError: String
  ) {
    let parts = rawValue.split(
      separator: "|",
      maxSplits: 6,
      omittingEmptySubsequences: false)
    let exported = parts.first.flatMap { Int($0) } ?? 0
    let failed = parts.dropFirst().first.flatMap { Int($0) } ?? 0
    let skipped = parts.dropFirst(2).first.flatMap { Int($0) } ?? 0
    let accounts = parts.dropFirst(3).first.flatMap { Int($0) } ?? 0
    let mailboxes = parts.dropFirst(4).first.flatMap { Int($0) } ?? 0
    let messages = parts.dropFirst(5).first.flatMap { Int($0) } ?? 0
    let lastError = parts.dropFirst(6).first.map(String.init) ?? ""
    return (exported, failed, skipped, accounts, mailboxes, messages, lastError)
  }

  private static func countEmlFiles(in directory: URL) -> Int {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil)
    else {
      return 0
    }

    var count = 0
    for case let fileURL as URL in enumerator
    where fileURL.pathExtension.lowercased() == "eml" {
      count += 1
    }
    return count
  }

  private static func ensureMailIsRunning() throws {
    let bundleIdentifier = "com.apple.mail"
    if waitForMailToFinishLaunching(bundleIdentifier: bundleIdentifier) {
      return
    }

    var launchError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      guard
        let applicationURL = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: bundleIdentifier)
      else {
        launchError = MacOSMailImporterError.mailLaunchFailed(
          "找不到 Mail.app。")
        semaphore.signal()
        return
      }

      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      NSWorkspace.shared.openApplication(
        at: applicationURL,
        configuration: configuration
      ) { _, error in
        launchError = error
        semaphore.signal()
      }
    }

    if semaphore.wait(timeout: .now() + 20) == .timedOut {
      throw MacOSMailImporterError.mailLaunchFailed("启动 Mail.app 超时。")
    }
    if let launchError {
      throw MacOSMailImporterError.mailLaunchFailed(
        launchError.localizedDescription)
    }

    if waitForMailToFinishLaunching(bundleIdentifier: bundleIdentifier) {
      Thread.sleep(forTimeInterval: 0.5)
      return
    }

    throw MacOSMailImporterError.mailLaunchFailed("Mail.app 未进入运行状态。")
  }

  private static func waitForMailToFinishLaunching(
    bundleIdentifier: String
  ) -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first {
        if application.isFinishedLaunching {
          return true
        }
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return false
  }

  private static func describeMailApplicationState() -> [String: Any] {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.mail")
    guard let application = applications.first else {
      return [
        "running": false,
        "count": applications.count,
      ]
    }

    return [
      "running": true,
      "count": applications.count,
      "pid": Int(application.processIdentifier),
      "isFinishedLaunching": application.isFinishedLaunching,
      "isTerminated": application.isTerminated,
    ]
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func runAppleScript(_ source: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw MacOSMailImporterError.scriptFailed(error.localizedDescription)
    }

    if let scriptData = (source + "\n").data(using: .utf8) {
      stdinPipe.fileHandleForWriting.write(scriptData)
    }
    try? stdinPipe.fileHandleForWriting.close()

    process.waitUntilExit()

    let stdout = String(
      data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderr = String(
      data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
      let message = stderr.isEmpty ? stdout : stderr
      throw MacOSMailImporterError.scriptFailed(
        message.isEmpty ? "AppleScript 执行失败。" : message)
    }

    return stdout
  }

  private static func writeDiagnostics(
    _ payload: [String: Any],
    to exportDirectory: URL
  ) throws {
    var diagnostics = payload
    diagnostics["writtenAt"] = ISO8601DateFormatter().string(from: Date())
    let data = try JSONSerialization.data(
      withJSONObject: diagnostics,
      options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: exportDirectory.appendingPathComponent("diagnostics.json"),
      options: .atomic)
  }

  private static func describeAppleScriptError(_ error: NSDictionary) -> String {
    let message = error[NSAppleScript.errorMessage] as? String
    let number = error[NSAppleScript.errorNumber] as? NSNumber
    if let message, let number {
      return "\(message) (\(number.intValue))"
    }
    if let message {
      return message
    }
    return error.description
  }
}

private final class MailImportProgressMonitor {
  init(
    progressFile: URL,
    exportDirectory: URL,
    progressSink: @escaping ([String: Any]) -> Void = { _ in }
  ) {
    self.progressFile = progressFile
    self.exportDirectory = exportDirectory
    self.progressSink = progressSink
  }

#if canImport(FlutterMacOS)
  convenience init(
    progressFile: URL,
    exportDirectory: URL,
    channel: FlutterMethodChannel
  ) {
    self.init(
      progressFile: progressFile,
      exportDirectory: exportDirectory,
      progressSink: { payload in
        DispatchQueue.main.async {
          channel.invokeMethod("mailImportProgress", arguments: payload)
        }
      })
  }
#endif

  private let progressFile: URL
  private let exportDirectory: URL
  private let progressSink: ([String: Any]) -> Void
  private let queue = DispatchQueue(
    label: "lico.macos_mail_importer.progress")
  private var timer: DispatchSourceTimer?
  private var readOffset: UInt64 = 0
  private var pendingText = ""
  private var latestDeferredPayload: [String: Any]?
  private var lastDeferredPayloadSentAt = Date.distantPast

  func start() {
    queue.async {
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(16))
      timer.setEventHandler { [weak self] in
        self?.readPendingLines()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
      readPendingLines()
      if !pendingText.isEmpty {
        handleLine(pendingText)
        pendingText = ""
      }
      flushDeferredPayload(force: true)
    }
  }

  func send(_ payload: [String: Any]) {
    progressSink(payload)
  }

  private func readPendingLines() {
    defer {
      flushDeferredPayload(force: false)
    }

    guard let fileHandle = try? FileHandle(forReadingFrom: progressFile) else {
      return
    }
    defer {
      try? fileHandle.close()
    }

    fileHandle.seek(toFileOffset: readOffset)
    let data = fileHandle.readDataToEndOfFile()
    readOffset = fileHandle.offsetInFile
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
      return
    }

    pendingText += text
    let hasTrailingLineBreak = pendingText.hasSuffix("\n")
    var lines = pendingText.components(separatedBy: .newlines)
    pendingText = hasTrailingLineBreak ? "" : (lines.popLast() ?? "")
    for line in lines where !line.isEmpty {
      handleLine(line)
    }
  }

  private func handleLine(_ line: String) {
    let parts = line.components(separatedBy: "\t")
    guard parts.count >= 8 else {
      return
    }

    let payload: [String: Any] = [
      "kind": parts[0],
      "sequence": Int(parts[1]) ?? 0,
      "totalCount": Int(parts[2]) ?? 0,
      "exportedCount": Int(parts[3]) ?? 0,
      "failedCount": Int(parts[4]) ?? 0,
      "skippedCount": Int(parts[5]) ?? 0,
      "title": parts[6],
      "detail": parts[7],
      "exportDirectory": exportDirectory.path,
    ]

    var enrichedPayload = payload
    if parts.count > 8 {
      enrichedPayload["messageKey"] = parts[8]
    }
    if parts.count > 9 {
      enrichedPayload["account"] = parts[9]
    }
    if parts.count > 10 {
      enrichedPayload["mailboxPath"] = parts[10]
    }
    if parts.count > 11 {
      enrichedPayload["sender"] = parts[11]
    }
    if parts.count > 12 {
      enrichedPayload["recipients"] = parts[12]
    }
    if parts.count > 13 {
      enrichedPayload["cc"] = parts[13]
    }
    if parts.count > 14 {
      enrichedPayload["dateSent"] = parts[14]
    }
    if parts.count > 15 {
      enrichedPayload["dateReceived"] = parts[15]
    }
    if parts.count > 16 {
      enrichedPayload["fileName"] = parts[16]
    }
    if parts.count > 17 {
      enrichedPayload["sourceHash"] = parts[17]
    }
    if parts.count > 18 {
      enrichedPayload["byteSize"] = Int(parts[18]) ?? 0
    }
    if parts.count > 19 {
      enrichedPayload["error"] = parts[19]
    }
    if parts.count > 20 {
      enrichedPayload["status"] = parts[20]
    }

    emit(enrichedPayload)
  }

  private func emit(_ payload: [String: Any]) {
    let kind = payload["kind"] as? String ?? ""
    switch kind {
    case "started", "scanning", "planned", "exported", "skipped", "failed", "paused",
      "resumed", "completed":
      flushDeferredPayload(force: true)
      send(payload)
      lastDeferredPayloadSentAt = Date()
    default:
      latestDeferredPayload = payload
    }
  }

  private func flushDeferredPayload(force: Bool) {
    guard let payload = latestDeferredPayload else {
      return
    }
    let now = Date()
    if !force && now.timeIntervalSince(lastDeferredPayloadSentAt) < 0.05 {
      return
    }
    latestDeferredPayload = nil
    lastDeferredPayloadSentAt = now
    send(payload)
  }
}

private struct MailExportDedupeRequest {
  let sequence: Int
  let messageKey: String
  let targetPath: String
  let sourceTempPath: String
  let mode: String

  init?(tsvLine: String) {
    let parts = tsvLine.components(separatedBy: "\t")
    guard parts.count >= 4, let parsedSequence = Int(parts[0]) else {
      return nil
    }
    sequence = parsedSequence
    messageKey = parts[1]
    targetPath = parts[2]
    sourceTempPath = parts[3]
    mode = parts.count > 4 ? parts[4] : "verify"
  }
}

private struct MailExportDedupeResult {
  let sequence: Int
  let decision: String
  let resolvedPath: String
  let sourceHash: String
  let byteSize: UInt64
  let error: String

  var tsvLine: String {
    [
      "\(sequence)",
      decision,
      resolvedPath,
      sourceHash,
      "\(byteSize)",
      error,
    ].map(Self.tsvSafe).joined(separator: "\t")
  }

  static func success(
    sequence: Int,
    decision: String,
    resolvedPath: String,
    sourceHash: String,
    byteSize: UInt64
  ) -> MailExportDedupeResult {
    MailExportDedupeResult(
      sequence: sequence,
      decision: decision,
      resolvedPath: resolvedPath,
      sourceHash: sourceHash,
      byteSize: byteSize,
      error: "-")
  }

  static func failure(
    sequence: Int,
    error: Error
  ) -> MailExportDedupeResult {
    MailExportDedupeResult(
      sequence: sequence,
      decision: "error",
      resolvedPath: "",
      sourceHash: "",
      byteSize: 0,
      error: String(describing: error))
  }

  private static func tsvSafe(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }
}

private final class MailExportDeduperCoordinator {
  init(
    requestsFile: URL,
    resultsDirectory: URL,
    manifestFile: URL
  ) {
    self.requestsFile = requestsFile
    self.resultsDirectory = resultsDirectory
    self.store = MailExportDeduperStore(manifestFile: manifestFile)
  }

  private let requestsFile: URL
  private let resultsDirectory: URL
  private let store: MailExportDeduperStore
  private let queue = DispatchQueue(
    label: "lico.mail_export_deduper",
    qos: .utility)
  private var timer: DispatchSourceTimer?
  private var readOffset: UInt64 = 0
  private var pendingText = ""

  func start() {
    queue.async {
      self.prepare()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(10))
      timer.setEventHandler { [weak self] in
        self?.readPendingLines()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func stopAndFlush() {
    queue.sync {
      timer?.cancel()
      timer = nil
      readPendingLines()
      if !pendingText.isEmpty {
        handleLine(pendingText)
        pendingText = ""
      }
      store.flushManifest()
    }
  }

  private func prepare() {
    try? FileManager.default.createDirectory(
      at: resultsDirectory,
      withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: requestsFile.path) {
      FileManager.default.createFile(atPath: requestsFile.path, contents: nil)
    }
    store.prepare()
  }

  private func readPendingLines() {
    guard let fileHandle = try? FileHandle(forReadingFrom: requestsFile) else {
      return
    }
    defer {
      try? fileHandle.close()
    }

    fileHandle.seek(toFileOffset: readOffset)
    let data = fileHandle.readDataToEndOfFile()
    readOffset = fileHandle.offsetInFile
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
      return
    }

    pendingText += text
    let hasTrailingLineBreak = pendingText.hasSuffix("\n")
    var lines = pendingText.components(separatedBy: .newlines)
    pendingText = hasTrailingLineBreak ? "" : (lines.popLast() ?? "")
    for line in lines where !line.isEmpty {
      handleLine(line)
    }
  }

  private func handleLine(_ line: String) {
    guard let request = MailExportDedupeRequest(tsvLine: line) else {
      return
    }

    let result: MailExportDedupeResult
    do {
      if request.mode == "lookup" {
        result = try store.lookupExisting(request)
      } else {
        result = try store.process(request)
      }
    } catch {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: request.sourceTempPath))
      result = .failure(sequence: request.sequence, error: error)
    }
    writeResult(result)
  }

  private func writeResult(_ result: MailExportDedupeResult) {
    let resultURL = resultsDirectory.appendingPathComponent(
      "\(Self.paddedSequence(result.sequence)).tsv")
    let tempURL = resultURL.deletingLastPathComponent().appendingPathComponent(
      "\(resultURL.lastPathComponent).tmp")
    guard let data = "\(result.tsvLine)\n".data(using: .utf8) else {
      return
    }
    do {
      try data.write(to: tempURL, options: [.atomic])
      if FileManager.default.fileExists(atPath: resultURL.path) {
        try FileManager.default.removeItem(at: resultURL)
      }
      try FileManager.default.moveItem(at: tempURL, to: resultURL)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }

  private static func paddedSequence(_ sequence: Int) -> String {
    String(format: "%06d", sequence)
  }
}

private final class MailExportDeduperStore {
  init(manifestFile: URL) {
    self.manifestFile = manifestFile
  }

  private static let manifestFlushBatchSize = 128

  private struct FileMetadata: Equatable {
    let byteSize: UInt64
    let sha256: String
  }

  private struct Record {
    let messageKey: String
    var fileName: String
    var byteSize: UInt64
    var sha256: String
    var updatedAt: String

    init?(_ line: String) {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 5 else {
        return nil
      }
      messageKey = parts[0]
      fileName = parts[1]
      byteSize = UInt64(parts[2]) ?? 0
      sha256 = parts[3]
      updatedAt = parts[4]
    }

    init(
      messageKey: String,
      fileName: String,
      metadata: FileMetadata
    ) {
      self.messageKey = messageKey
      self.fileName = fileName
      byteSize = metadata.byteSize
      sha256 = metadata.sha256
      updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    var tsvLine: String {
      [
        messageKey,
        fileName,
        "\(byteSize)",
        sha256,
        updatedAt,
      ].map(Self.tsvSafe).joined(separator: "\t")
    }

    func matches(_ metadata: FileMetadata) -> Bool {
      byteSize == metadata.byteSize && sha256 == metadata.sha256
    }

    private static func tsvSafe(_ value: String) -> String {
      value
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    }
  }

  private let manifestFile: URL
  private var recordsByKey: [String: Record] = [:]
  private var isPrepared = false
  private var dirtyRecordCount = 0

  func prepare() {
    guard !isPrepared else {
      return
    }
    try? FileManager.default.createDirectory(
      at: manifestFile.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: manifestFile.path) {
      FileManager.default.createFile(atPath: manifestFile.path, contents: nil)
    }
    loadManifest()
    isPrepared = true
  }

  func process(_ request: MailExportDedupeRequest) throws -> MailExportDedupeResult {
    prepare()
    let fileManager = FileManager.default
    let targetURL = URL(fileURLWithPath: request.targetPath)
    let sourceURL = URL(fileURLWithPath: request.sourceTempPath)
    let sourceMetadata = try preparedSourceMetadata(for: sourceURL)
    let messageKey = stableKey(
      messageKey: request.messageKey,
      fallback: targetURL.lastPathComponent)
    let targetDirectory = targetURL.deletingLastPathComponent()

    if let record = recordsByKey[messageKey], !record.fileName.isEmpty {
      let existingURL = targetDirectory.appendingPathComponent(record.fileName)
      if fileManager.fileExists(atPath: existingURL.path) {
        if record.matches(sourceMetadata) {
          try? fileManager.removeItem(at: sourceURL)
          upsert(
            messageKey: messageKey,
            resolvedURL: existingURL,
            metadata: sourceMetadata)
          return .success(
            sequence: request.sequence,
            decision: "skip",
            resolvedPath: existingURL.path,
            sourceHash: sourceMetadata.sha256,
            byteSize: sourceMetadata.byteSize)
        }
        if let existingMetadata = try? metadata(for: existingURL),
          existingMetadata == sourceMetadata
        {
          try? fileManager.removeItem(at: sourceURL)
          upsert(
            messageKey: messageKey,
            resolvedURL: existingURL,
            metadata: sourceMetadata)
          return .success(
            sequence: request.sequence,
            decision: "skip",
            resolvedPath: existingURL.path,
            sourceHash: sourceMetadata.sha256,
            byteSize: sourceMetadata.byteSize)
        }
      }
    }

    let resolution = try resolveDestination(
      targetURL: targetURL,
      sourceMetadata: sourceMetadata)
    switch resolution.decision {
    case "skip":
      try? fileManager.removeItem(at: sourceURL)
    default:
      try waitForPreparedSource(at: sourceURL)
      try fileManager.createDirectory(
        at: resolution.url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: resolution.url.path) {
        throw NSError(
          domain: "MailExportDeduper",
          code: 3,
          userInfo: [
            NSLocalizedDescriptionKey: "目标邮件文件已存在：\(resolution.url.path)"
          ])
      }
      try fileManager.moveItem(at: sourceURL, to: resolution.url)
    }

    upsert(
      messageKey: messageKey,
      resolvedURL: resolution.url,
      metadata: sourceMetadata)
    return .success(
      sequence: request.sequence,
      decision: resolution.decision,
      resolvedPath: resolution.url.path,
      sourceHash: sourceMetadata.sha256,
      byteSize: sourceMetadata.byteSize)
  }

  func lookupExisting(_ request: MailExportDedupeRequest) throws
    -> MailExportDedupeResult
  {
    prepare()
    let targetURL = URL(fileURLWithPath: request.targetPath)
    let messageKey = stableKey(
      messageKey: request.messageKey,
      fallback: targetURL.lastPathComponent)
    guard
      let record = recordsByKey[messageKey],
      !record.fileName.isEmpty
    else {
      return .success(
        sequence: request.sequence,
        decision: "miss",
        resolvedPath: "",
        sourceHash: "",
        byteSize: 0)
    }

    let existingURL = targetURL
      .deletingLastPathComponent()
      .appendingPathComponent(record.fileName)
    guard FileManager.default.fileExists(atPath: existingURL.path) else {
      return .success(
        sequence: request.sequence,
        decision: "miss",
        resolvedPath: "",
        sourceHash: "",
        byteSize: 0)
    }

    return .success(
      sequence: request.sequence,
      decision: "skip",
      resolvedPath: existingURL.path,
      sourceHash: record.sha256,
      byteSize: record.byteSize)
  }

  func flushManifest() {
    saveManifest(force: true)
  }

  private func loadManifest() {
    recordsByKey.removeAll()
    guard let text = try? String(contentsOf: manifestFile, encoding: .utf8) else {
      return
    }
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      guard let record = Record(line), !record.messageKey.isEmpty else {
        continue
      }
      recordsByKey[record.messageKey] = record
    }
  }

  private func upsert(
    messageKey: String,
    resolvedURL: URL,
    metadata: FileMetadata
  ) {
    recordsByKey[messageKey] = Record(
      messageKey: messageKey,
      fileName: resolvedURL.lastPathComponent,
      metadata: metadata)
    dirtyRecordCount += 1
    saveManifest(force: false)
  }

  private func saveManifest(force: Bool) {
    guard dirtyRecordCount > 0 else {
      return
    }
    guard force || dirtyRecordCount >= Self.manifestFlushBatchSize else {
      return
    }
    let rows = recordsByKey.keys.sorted()
      .compactMap { recordsByKey[$0]?.tsvLine }
      .joined(separator: "\n")
    guard let data = "\(rows)\(rows.isEmpty ? "" : "\n")".data(using: .utf8) else {
      return
    }
    let tempURL = manifestFile.deletingLastPathComponent().appendingPathComponent(
      "\(manifestFile.lastPathComponent).tmp")
    do {
      try data.write(to: tempURL, options: [.atomic])
      if FileManager.default.fileExists(atPath: manifestFile.path) {
        try FileManager.default.removeItem(at: manifestFile)
      }
      try FileManager.default.moveItem(at: tempURL, to: manifestFile)
      dirtyRecordCount = 0
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }

  private func resolveDestination(
    targetURL: URL,
    sourceMetadata: FileMetadata
  ) throws -> (decision: String, url: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: targetURL.path) {
      return ("write", targetURL)
    }
    if let existingMetadata = try? metadata(for: targetURL),
      existingMetadata == sourceMetadata
    {
      return ("skip", targetURL)
    }

    let basePath: String
    if targetURL.path.hasSuffix(".eml") {
      basePath = String(targetURL.path.dropLast(4))
    } else {
      basePath = targetURL.path
    }

    for copyCounter in 2...999_999 {
      let candidateURL = URL(
        fileURLWithPath: "\(basePath) - 副本 \(copyCounter).eml")
      if !fileManager.fileExists(atPath: candidateURL.path) {
        return ("write", candidateURL)
      }
      if let existingMetadata = try? metadata(for: candidateURL),
        existingMetadata == sourceMetadata
      {
        return ("skip", candidateURL)
      }
    }

    throw NSError(
      domain: "MailExportDeduper",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "无法为重复邮件生成可用文件名。"])
  }

  private func stableKey(messageKey: String, fallback: String) -> String {
    let trimmed = messageKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return "file:\(fallback)"
  }

  private func metadata(for url: URL) throws -> FileMetadata {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let byteSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    return FileMetadata(
      byteSize: byteSize,
      sha256: try sha256Hex(for: url))
  }

  private func preparedSourceMetadata(for url: URL) throws -> FileMetadata {
    try waitForPreparedSource(at: url)
    return try metadata(for: url)
  }

  private func waitForPreparedSource(at url: URL) throws {
    let fileManager = FileManager.default
    var lastObservedSize: UInt64?

    for attempt in 0..<120 {
      if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
        let byteSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if byteSize > 0 {
          if lastObservedSize == byteSize || attempt >= 2 {
            return
          }
          lastObservedSize = byteSize
        }
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    throw NSError(
      domain: "MailExportDeduper",
      code: 5,
      userInfo: [
        NSLocalizedDescriptionKey: "临时邮件源文件未及时落盘：\(url.path)"
      ])
  }

  private func sha256Hex(for url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    var hasher = SHA256()
    while true {
      let chunk = handle.readData(ofLength: 1024 * 1024)
      if chunk.isEmpty {
        break
      }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private struct MailIndexEvent {
  let sequence: Int
  let messageKey: String
  let fileName: String
  let account: String
  let mailboxPath: String
  let subject: String
  let sender: String
  let recipients: String
  let cc: String
  let dateSent: String
  let dateReceived: String
  let status: String
  let error: String
  let sourceHash: String
  let byteSize: String

  init?(tsvLine: String) {
    let parts = tsvLine.components(separatedBy: "\t")
    guard parts.count >= 13 else {
      return nil
    }
    sequence = Int(parts[0]) ?? 0
    messageKey = parts[1]
    fileName = parts[2]
    account = parts[3]
    mailboxPath = parts[4]
    subject = parts[5]
    sender = parts[6]
    recipients = parts[7]
    cc = parts[8]
    dateSent = parts[9]
    dateReceived = parts[10]
    status = parts[11]
    error = parts[12]
    sourceHash = parts.count > 13 ? parts[13] : ""
    byteSize = parts.count > 14 ? parts[14] : ""
  }

  init?(jsonObject: [String: Any]) {
    func stringValue(_ key: String) -> String {
      if let value = jsonObject[key] as? String {
        return value
      }
      if let value = jsonObject[key] as? NSNumber {
        return value.stringValue
      }
      return ""
    }

    if let value = jsonObject["sequence"] as? Int {
      sequence = value
    } else if let value = jsonObject["sequence"] as? NSNumber {
      sequence = value.intValue
    } else {
      sequence = Int(stringValue("sequence")) ?? 0
    }
    messageKey = stringValue("messageKey")
    fileName = stringValue("fileName")
    account = stringValue("account")
    mailboxPath = stringValue("mailboxPath")
    subject = stringValue("subject")
    sender = stringValue("sender")
    recipients = stringValue("recipients")
    cc = stringValue("cc")
    dateSent = stringValue("dateSent")
    dateReceived = stringValue("dateReceived")
    status = stringValue("status")
    error = stringValue("error")
    sourceHash = stringValue("sourceHash")
    byteSize = stringValue("byteSize")

    guard !stableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
  }

  init(sequence: Int, manifestRecord: MailIndexManifestRecord) {
    self.sequence = sequence
    messageKey = manifestRecord.messageKey
    fileName = manifestRecord.fileName
    account = ""
    mailboxPath = ""
    subject = URL(fileURLWithPath: manifestRecord.fileName)
      .deletingPathExtension()
      .lastPathComponent
    sender = ""
    recipients = ""
    cc = ""
    dateSent = ""
    dateReceived = manifestRecord.updatedAt
    status = "existing"
    error = ""
    sourceHash = manifestRecord.sha256
    byteSize = "\(manifestRecord.byteSize)"
  }

  var stableKey: String {
    if !messageKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return messageKey
    }
    return fileName.isEmpty ? "sequence:\(sequence)" : "file:\(fileName)"
  }

  var jsonObject: [String: Any] {
    [
      "sequence": sequence,
      "messageKey": messageKey,
      "fileName": fileName,
      "account": account,
      "mailboxPath": mailboxPath,
      "subject": subject,
      "sender": sender,
      "recipients": recipients,
      "cc": cc,
      "dateSent": dateSent,
      "dateReceived": dateReceived,
      "status": status,
      "error": error,
      "sourceHash": sourceHash,
      "byteSize": byteSize,
      "seenAt": MailIndexStore.isoTimestamp(),
    ]
  }
}

private struct MailIndexManifestRecord {
  let messageKey: String
  let fileName: String
  let byteSize: UInt64
  let sha256: String
  let updatedAt: String

  init?(tsvLine: String) {
    let parts = tsvLine.components(separatedBy: "\t")
    guard parts.count >= 5 else {
      return nil
    }
    messageKey = parts[0]
    fileName = parts[1]
    byteSize = UInt64(parts[2]) ?? 0
    sha256 = parts[3]
    updatedAt = parts[4]
  }

  var stableKey: String {
    let trimmed = messageKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return fileName.isEmpty ? "" : "file:\(fileName)"
  }
}

private struct MailIndexDocument {
  var docId: Int
  var messageKey: String
  var fileName: String
  var subject: String
  var sender: String
  var recipients: String
  var cc: String
  var dateSent: String
  var dateReceived: String
  var account: String
  var mailboxPath: String
  var status: String
  var lastSeenAt: String
  var error: String
  var sourceHash: String
  var byteSize: String
  var taxonomyPath: String

  init(
    docId: Int,
    event: MailIndexEvent,
    taxonomyRules: [MailIndexTaxonomyRule]
  ) {
    self.docId = docId
    messageKey = event.stableKey
    fileName = event.fileName
    subject = event.subject
    sender = event.sender
    recipients = event.recipients
    cc = event.cc
    dateSent = event.dateSent
    dateReceived = event.dateReceived
    account = event.account
    mailboxPath = event.mailboxPath
    status = event.status
    lastSeenAt = MailIndexStore.isoTimestamp()
    error = event.error
    sourceHash = event.sourceHash
    byteSize = event.byteSize
    taxonomyPath = MailIndexTaxonomy.classify(
      subject: event.subject,
      sender: event.sender,
      mailboxPath: event.mailboxPath,
      rules: taxonomyRules
    )
  }

  init?(
    tsvLine: String,
    taxonomyRules: [MailIndexTaxonomyRule] = MailIndexTaxonomy.fallbackRules
  ) {
    let parts = tsvLine.components(separatedBy: "\t")
    guard parts.count >= 14, let parsedDocId = Int(parts[0]) else {
      return nil
    }
    docId = parsedDocId
    messageKey = parts[1]
    fileName = parts[2]
    subject = parts[3]
    sender = parts[4]
    recipients = parts[5]
    cc = parts[6]
    dateSent = parts[7]
    dateReceived = parts[8]
    account = parts[9]
    mailboxPath = parts[10]
    status = parts[11]
    lastSeenAt = parts[12]
    error = parts[13]
    sourceHash = parts.count > 14 ? parts[14] : ""
    byteSize = parts.count > 15 ? parts[15] : ""
    taxonomyPath = parts.count > 16 ? parts[16] : MailIndexTaxonomy.classify(
      subject: subject,
      sender: sender,
      mailboxPath: mailboxPath,
      rules: taxonomyRules
    )
  }

  var tsvLine: String {
    [
      "\(docId)",
      messageKey,
      fileName,
      subject,
      sender,
      recipients,
      cc,
      dateSent,
      dateReceived,
      account,
      mailboxPath,
      status,
      lastSeenAt,
      error,
      sourceHash,
      byteSize,
      taxonomyPath,
    ].map(MailIndexStore.tsvSafe).joined(separator: "\t")
  }

  var indexSignature: String {
    [
      subject,
      sender,
      recipients,
      cc,
      account,
      mailboxPath,
      taxonomyPath,
      dateSent,
      dateReceived,
      status,
    ].joined(separator: "\u{1f}")
  }

  func payload(downloadsDirectory: URL) -> [String: Any] {
    let fileURL = downloadsDirectory.appendingPathComponent(fileName)
    return [
      "docId": docId,
      "messageKey": messageKey,
      "fileName": fileName,
      "path": fileURL.path,
      "subject": subject,
      "sender": sender,
      "recipients": recipients,
      "cc": cc,
      "dateSent": dateSent,
      "dateReceived": dateReceived,
      "account": account,
      "mailboxPath": mailboxPath,
      "status": status,
      "lastSeenAt": lastSeenAt,
      "error": error,
      "sourceHash": sourceHash,
      "byteSize": byteSize,
      "taxonomyPath": taxonomyPath,
    ]
  }
}

private final class MailIndexCoordinator {
  init(
    indexDirectory: URL,
    downloadsDirectory: URL,
    manifestFile: URL,
    sourceEventsFile: URL
  ) {
    self.store = MailIndexStore(
      baseDirectory: indexDirectory,
      downloadsDirectory: downloadsDirectory,
      manifestFile: manifestFile)
    self.sourceEventsFile = sourceEventsFile
  }

  private let store: MailIndexStore
  private let sourceEventsFile: URL
  private let queue = DispatchQueue(
    label: "lico.mail_index.coordinator",
    qos: .utility)
  private var timer: DispatchSourceTimer?
  private var readOffset: UInt64 = 0
  private var pendingText = ""

  func start() {
    queue.async {
      self.store.prepare()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(250))
      timer.setEventHandler { [weak self] in
        self?.readPendingLines()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func stopAndFlush() {
    queue.sync {
      timer?.cancel()
      timer = nil
      readPendingLines()
      if !pendingText.isEmpty {
        handleLine(pendingText)
        pendingText = ""
      }
      store.flushPendingSegment()
      store.saveDocsAndState()
    }
  }

  private func readPendingLines() {
    guard let fileHandle = try? FileHandle(forReadingFrom: sourceEventsFile) else {
      return
    }
    defer {
      try? fileHandle.close()
    }

    fileHandle.seek(toFileOffset: readOffset)
    let data = fileHandle.readDataToEndOfFile()
    readOffset = fileHandle.offsetInFile
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
      return
    }

    pendingText += text
    let hasTrailingLineBreak = pendingText.hasSuffix("\n")
    var lines = pendingText.components(separatedBy: .newlines)
    pendingText = hasTrailingLineBreak ? "" : (lines.popLast() ?? "")
    for line in lines where !line.isEmpty {
      handleLine(line)
    }
  }

  private func handleLine(_ line: String) {
    guard let event = MailIndexEvent(tsvLine: line) else {
      return
    }
    store.ingest(event)
  }
}

private final class MailIndexMergeScheduler {
  static let shared = MailIndexMergeScheduler()

  private let queue = DispatchQueue(
    label: "lico.mail_index.merge_scheduler",
    qos: .utility)
  private var scheduledKeys: Set<String> = []
  private let maxBatchesPerWake = 6

  private init() {}

  func requestMerge(baseDirectory: URL, downloadsDirectory: URL) {
    let key = baseDirectory.standardizedFileURL.path
    queue.async {
      guard !self.scheduledKeys.contains(key) else {
        return
      }
      self.scheduledKeys.insert(key)
      self.queue.asyncAfter(deadline: .now() + .seconds(2)) {
        self.scheduledKeys.remove(key)
        self.mergePendingSegments(
          baseDirectory: baseDirectory,
          downloadsDirectory: downloadsDirectory)
      }
    }
  }

  private func mergePendingSegments(
    baseDirectory: URL,
    downloadsDirectory: URL
  ) {
    let store = MailIndexStore(
      baseDirectory: baseDirectory,
      downloadsDirectory: downloadsDirectory,
      schedulesMergeRequests: false)
    var batches = 0
    while batches < maxBatchesPerWake, store.mergeSegmentsIfNeeded() {
      batches += 1
    }
    if batches == maxBatchesPerWake {
      requestMerge(
        baseDirectory: baseDirectory,
        downloadsDirectory: downloadsDirectory)
    }
  }
}

private final class MailIndexStore {
  init(
    baseDirectory: URL,
    downloadsDirectory: URL,
    manifestFile: URL? = nil,
    schedulesMergeRequests: Bool = true
  ) {
    self.baseDirectory = baseDirectory
    self.downloadsDirectory = downloadsDirectory
    self.schedulesMergeRequests = schedulesMergeRequests
    self.segmentsDirectory = baseDirectory.appendingPathComponent(
      "segments",
      isDirectory: true)
    self.eventsFile = baseDirectory.appendingPathComponent("events.jsonl")
    self.docsFile = baseDirectory.appendingPathComponent("docs.tsv")
    self.stateFile = baseDirectory.appendingPathComponent("state.json")
    self.manifestFile = manifestFile ?? downloadsDirectory.appendingPathComponent(
      "dedupe-manifest.tsv")
    self.vocabularyFile = baseDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("expert-vocabulary.json")
    self.taxonomyRules = MailIndexTaxonomy.loadRules(from: vocabularyFile)
    self.taxonomySignature = MailIndexTaxonomy.signature(from: vocabularyFile)
  }

  private static let indexAlgorithmVersion = 3
  private static let segmentBatchSize = 2048
  private static let mergeSegmentThreshold = 8
  private static let mergeFanIn = 8
  private static let isoFormatter = ISO8601DateFormatter()

  private let baseDirectory: URL
  private let downloadsDirectory: URL
  private let schedulesMergeRequests: Bool
  private let segmentsDirectory: URL
  private let eventsFile: URL
  private let docsFile: URL
  private let stateFile: URL
  private let manifestFile: URL
  private let vocabularyFile: URL
  private let taxonomyRules: [MailIndexTaxonomyRule]
  private let taxonomySignature: String
  private var docsByKey: [String: MailIndexDocument] = [:]
  private var docsById: [Int: MailIndexDocument] = [:]
  private var pendingDocuments: [MailIndexDocument] = []
  private var pendingSignatures: [Int: String] = [:]
  private var nextDocId = 1
  private var nextSegmentId = 1
  private var recoveredEventOffset: UInt64 = 0
  private var loadedIndexAlgorithmVersion = 0
  private var loadedTaxonomySignature = ""
  private var didLoadState = false

  static func isoTimestamp() -> String {
    isoFormatter.string(from: Date())
  }

  static func tsvSafe(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }

  func prepare() {
    prepareDirectories()
    loadDocs()
    loadState()
    if !FileManager.default.fileExists(atPath: eventsFile.path) {
      FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
    }
    let didResetForAlgorithm = loadedIndexAlgorithmVersion !=
      Self.indexAlgorithmVersion || loadedTaxonomySignature != taxonomySignature
    if didResetForAlgorithm {
      resetDerivedIndexForRebuild()
    }
    recoverFromEventLogIfNeeded()
    if didResetForAlgorithm {
      ingestManifestFallbackEvents()
      flushPendingSegment()
      saveDocsAndState()
    }
    rebuildSegmentsIfNeeded()
  }

  func rebuildPayload() -> [String: Any] {
    prepareDirectories()
    if !FileManager.default.fileExists(atPath: eventsFile.path) {
      FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
    }
    resetDerivedIndexForRebuild()
    recoverFromEventLogIfNeeded()
    ingestManifestFallbackEvents()
    flushPendingSegment()
    saveDocsAndState()
    return statsPayload()
  }

  func ingest(_ event: MailIndexEvent) {
    ingest(event, appendToEventLog: true)
  }

  private func ingest(_ event: MailIndexEvent, appendToEventLog: Bool) {
    prepareIfNeeded()
    if appendToEventLog, let byteCount = appendEvent(event) {
      recoveredEventOffset += UInt64(byteCount)
    }

    let existing = docsByKey[event.stableKey]
    let docId = existing?.docId ?? nextDocId
    if existing == nil {
      nextDocId += 1
    }
    var document = MailIndexDocument(
      docId: docId,
      event: event,
      taxonomyRules: taxonomyRules)
    if document.fileName.isEmpty, let existing {
      document.fileName = existing.fileName
    }

    let oldSignature = existing?.indexSignature
    docsByKey[document.messageKey] = document
    docsById[document.docId] = document
    if oldSignature != document.indexSignature {
      pendingDocuments.append(document)
      pendingSignatures[document.docId] = document.indexSignature
    }

    if pendingDocuments.count >= Self.segmentBatchSize {
      flushPendingSegment()
      saveDocsAndState()
    }
  }

  func flushPendingSegment() {
    guard !pendingDocuments.isEmpty else {
      return
    }

    let uniqueDocuments = dedupePendingDocuments()
    pendingDocuments = []
    pendingSignatures.removeAll()
    guard !uniqueDocuments.isEmpty else {
      return
    }

    nextSegmentId = max(nextSegmentId, derivedNextSegmentId())
    let segmentName = String(format: "seg-%06d", nextSegmentId)
    nextSegmentId += 1
    writeSegment(name: segmentName, documents: uniqueDocuments)
  }

  func saveDocsAndState() {
    prepareIfNeeded()
    let docsText = docsById.keys.sorted()
      .compactMap { docsById[$0]?.tsvLine }
      .joined(separator: "\n")
    atomicWrite(
      "\(docsText)\(docsText.isEmpty ? "" : "\n")",
      to: docsFile)

    let state: [String: Any] = [
      "nextDocId": nextDocId,
      "nextSegmentId": nextSegmentId,
      "documentCount": docsById.count,
      "indexAlgorithmVersion": Self.indexAlgorithmVersion,
      "taxonomySignature": taxonomySignature,
      "segmentCount": segmentNames().count,
      "pendingDocumentCount": pendingDocuments.count,
      "recoveredEventOffset": recoveredEventOffset,
      "lastUpdatedAt": Self.isoTimestamp(),
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: state,
      options: [.prettyPrinted, .sortedKeys])
    {
      atomicWrite(data, to: stateFile)
    }
  }

  @discardableResult
  func mergeSegmentsIfNeeded() -> Bool {
    prepareIfNeeded()
    let names = segmentNames()
    guard names.count > Self.mergeSegmentThreshold else {
      return false
    }
    let mergeNames = segmentNamesForMerge(from: names)
    guard mergeNames.count > 1 else {
      return false
    }

    var merged: [String: Set<Int>] = [:]
    for name in mergeNames {
      for (term, ids) in postingsByTerm(segmentName: name) {
        merged[term, default: []].formUnion(ids)
      }
    }
    guard !merged.isEmpty else {
      return false
    }

    nextSegmentId = max(nextSegmentId, derivedNextSegmentId())
    let segmentName = String(format: "seg-%06d", nextSegmentId)
    nextSegmentId += 1
    writeSegment(name: segmentName, postings: merged, shouldRequestMerge: false)

    for name in mergeNames {
      try? FileManager.default.removeItem(
        at: segmentsDirectory.appendingPathComponent("\(name).lex"))
      try? FileManager.default.removeItem(
        at: segmentsDirectory.appendingPathComponent("\(name).post"))
      try? FileManager.default.removeItem(
        at: segmentsDirectory.appendingPathComponent("\(name).meta"))
    }
    saveDocsAndState()
    return true
  }

  func statsPayload() -> [String: Any] {
    prepare()
    let state = statePayload()
    return [
      "documentCount": docsById.count,
      "segmentCount": segmentNames().count,
      "pendingCount": max(0, segmentNames().count - Self.mergeSegmentThreshold),
      "lastUpdatedAt": state["lastUpdatedAt"] as? String ?? "",
      "indexDirectory": baseDirectory.path,
    ]
  }

  func searchPayload(
    query: String,
    filters: [String: Any],
    limit: Int,
    offset: Int
  ) -> [String: Any] {
    prepare()
    let terms = MailIndexTokenizer.terms(for: query)
    var candidateIds: Set<Int>
    if terms.isEmpty {
      candidateIds = Set(docsById.keys)
    } else {
      candidateIds = matchingDocIds(for: terms)
    }

    let filtered = candidateIds
      .compactMap { docsById[$0] }
      .filter { matches($0, filters: filters) }
      .sorted {
        if $0.dateReceived != $1.dateReceived {
          return $0.dateReceived > $1.dateReceived
        }
        return $0.docId > $1.docId
      }
    let page = filtered.dropFirst(offset).prefix(limit)
    return [
      "total": filtered.count,
      "results": page.map { $0.payload(downloadsDirectory: downloadsDirectory) },
    ]
  }

  func openPayload(docId: Int?, messageKey: String?) -> [String: Any]? {
    prepare()
    let document: MailIndexDocument?
    if let docId {
      document = docsById[docId]
    } else if let messageKey, !messageKey.isEmpty {
      document = docsByKey[messageKey]
    } else {
      document = nil
    }
    guard let document else {
      return nil
    }
    let fileURL = downloadsDirectory.appendingPathComponent(document.fileName)
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    return [
      "opened": true,
      "path": fileURL.path,
      "docId": document.docId,
      "messageKey": document.messageKey,
    ]
  }

  private func prepareIfNeeded() {
    if docsById.isEmpty && FileManager.default.fileExists(atPath: docsFile.path) {
      loadDocs()
    }
    prepareDirectories()
    if !didLoadState {
      loadState()
    }
  }

  private func loadDocs() {
    docsByKey.removeAll()
    docsById.removeAll()
    guard
      let text = try? String(contentsOf: docsFile, encoding: .utf8)
    else {
      return
    }
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      guard let document = MailIndexDocument(
        tsvLine: line,
        taxonomyRules: taxonomyRules)
      else {
        continue
      }
      docsByKey[document.messageKey] = document
      docsById[document.docId] = document
      nextDocId = max(nextDocId, document.docId + 1)
    }
  }

  private func loadState() {
    didLoadState = true
    guard
      let data = try? Data(contentsOf: stateFile),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      nextSegmentId = max(nextSegmentId, derivedNextSegmentId())
      return
    }
    nextDocId = max(nextDocId, json["nextDocId"] as? Int ?? 1)
    nextSegmentId = max(
      json["nextSegmentId"] as? Int ?? 1,
      derivedNextSegmentId())
    loadedIndexAlgorithmVersion = json["indexAlgorithmVersion"] as? Int ?? 0
    loadedTaxonomySignature = json["taxonomySignature"] as? String ?? ""
    if let value = json["recoveredEventOffset"] as? UInt64 {
      recoveredEventOffset = value
    } else if let value = json["recoveredEventOffset"] as? NSNumber {
      recoveredEventOffset = value.uint64Value
    } else if let value = json["recoveredEventOffset"] as? String {
      recoveredEventOffset = UInt64(value) ?? 0
    }
  }

  private func statePayload() -> [String: Any] {
    guard
      let data = try? Data(contentsOf: stateFile),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return json
  }

  private func appendEvent(_ event: MailIndexEvent) -> Int? {
    guard
      let data = try? JSONSerialization.data(withJSONObject: event.jsonObject),
      let line = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    let text = "\(line)\n"
    appendText(text, to: eventsFile)
    return text.data(using: .utf8)?.count
  }

  private func recoverFromEventLogIfNeeded() {
    guard FileManager.default.fileExists(atPath: eventsFile.path) else {
      return
    }
    let fileSize = eventLogSize()
    if recoveredEventOffset > fileSize {
      recoveredEventOffset = 0
    }
    guard recoveredEventOffset < fileSize else {
      return
    }
    guard let handle = try? FileHandle(forReadingFrom: eventsFile) else {
      return
    }
    defer {
      try? handle.close()
    }

    handle.seek(toFileOffset: recoveredEventOffset)
    let data = handle.readDataToEndOfFile()
    guard let lastNewline = data.lastIndex(of: 0x0A) else {
      return
    }
    let completeData = data.prefix(through: lastNewline)
    guard let text = String(data: completeData, encoding: .utf8) else {
      return
    }

    var recoveredCount = 0
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      guard
        let lineData = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
        let event = MailIndexEvent(jsonObject: object)
      else {
        continue
      }
      ingest(event, appendToEventLog: false)
      recoveredCount += 1
    }

    recoveredEventOffset += UInt64(completeData.count)
    if recoveredCount > 0 {
      flushPendingSegment()
      saveDocsAndState()
    } else {
      saveDocsAndState()
    }
  }

  private func ingestManifestFallbackEvents() {
    var sequence = docsById.count
    guard
      FileManager.default.fileExists(atPath: manifestFile.path),
      let text = try? String(contentsOf: manifestFile, encoding: .utf8)
    else {
      return
    }
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      guard let record = MailIndexManifestRecord(tsvLine: line) else {
        continue
      }
      let key = record.stableKey
      guard !key.isEmpty, docsByKey[key] == nil else {
        continue
      }
      let fileURL = downloadsDirectory.appendingPathComponent(record.fileName)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        continue
      }
      sequence += 1
      ingest(
        MailIndexEvent(sequence: sequence, manifestRecord: record),
        appendToEventLog: false)
    }
  }

  private func rebuildSegmentsIfNeeded() {
    guard segmentNames().isEmpty, !docsById.isEmpty else {
      return
    }
    pendingDocuments = docsById.keys.sorted().compactMap { docsById[$0] }
    pendingSignatures = Dictionary(
      uniqueKeysWithValues: pendingDocuments.map {
        ($0.docId, $0.indexSignature)
      })
    flushPendingSegment()
    saveDocsAndState()
  }

  private func resetDerivedIndexForRebuild() {
    docsByKey.removeAll()
    docsById.removeAll()
    pendingDocuments.removeAll()
    pendingSignatures.removeAll()
    nextDocId = 1
    nextSegmentId = 1
    recoveredEventOffset = 0
    loadedIndexAlgorithmVersion = Self.indexAlgorithmVersion
    loadedTaxonomySignature = taxonomySignature
    try? FileManager.default.removeItem(at: docsFile)
    try? FileManager.default.removeItem(at: stateFile)
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: segmentsDirectory,
        includingPropertiesForKeys: nil)
    else {
      return
    }
    for file in files {
      switch file.pathExtension {
      case "lex", "post", "meta", "tmp":
        try? FileManager.default.removeItem(at: file)
      default:
        continue
      }
    }
  }

  private func eventLogSize() -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: eventsFile.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func prepareDirectories() {
    try? FileManager.default.createDirectory(
      at: baseDirectory,
      withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: segmentsDirectory,
      withIntermediateDirectories: true)
  }

  private func dedupePendingDocuments() -> [MailIndexDocument] {
    var latest: [Int: MailIndexDocument] = [:]
    for document in pendingDocuments {
      latest[document.docId] = document
    }
    return latest.keys.sorted().compactMap { latest[$0] }
  }

  private func writeSegment(name: String, documents: [MailIndexDocument]) {
    var postings: [String: Set<Int>] = [:]
    for document in documents {
      for term in MailIndexTokenizer.terms(for: document) {
        postings[term, default: []].insert(document.docId)
      }
    }
    writeSegment(name: name, postings: postings)
  }

  private func writeSegment(
    name: String,
    postings: [String: Set<Int>],
    shouldRequestMerge: Bool = true
  ) {
    guard !postings.isEmpty else {
      return
    }

    var postData = Data()
    var lexRows: [String] = []
    for term in postings.keys.sorted() {
      let ids = postings[term, default: []].sorted()
      guard !ids.isEmpty else {
        continue
      }
      let offset = postData.count
      var previous = 0
      for id in ids {
        appendVarint(UInt32(max(0, id - previous)), to: &postData)
        previous = id
      }
      let byteLength = postData.count - offset
      lexRows.append(
        [
          term,
          "\(offset)",
          "\(byteLength)",
          "\(ids.count)",
        ].joined(separator: "\t"))
    }

    let lexURL = segmentsDirectory.appendingPathComponent("\(name).lex")
    let postURL = segmentsDirectory.appendingPathComponent("\(name).post")
    let metaURL = segmentsDirectory.appendingPathComponent("\(name).meta")
    atomicWrite(lexRows.joined(separator: "\n") + "\n", to: lexURL)
    atomicWrite(postData, to: postURL)
    let meta: [String: Any] = [
      "name": name,
      "createdAt": Self.isoTimestamp(),
      "termCount": lexRows.count,
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: meta,
      options: [.prettyPrinted, .sortedKeys])
    {
      atomicWrite(data, to: metaURL)
    }
    if shouldRequestMerge, schedulesMergeRequests {
      requestMergeIfNeeded()
    }
  }

  private func requestMergeIfNeeded() {
    guard segmentNames().count > Self.mergeSegmentThreshold else {
      return
    }
    MailIndexMergeScheduler.shared.requestMerge(
      baseDirectory: baseDirectory,
      downloadsDirectory: downloadsDirectory)
  }

  private func matchingDocIds(for terms: Set<String>) -> Set<Int> {
    var result: Set<Int>?
    for term in terms {
      var termMatches: Set<Int> = []
      for name in segmentNames() {
        termMatches.formUnion(postings(for: term, segmentName: name))
      }
      if let current = result {
        result = current.intersection(termMatches)
      } else {
        result = termMatches
      }
      if result?.isEmpty == true {
        break
      }
    }
    return result ?? []
  }

  private func postingsByTerm(segmentName: String) -> [String: Set<Int>] {
    let lexURL = segmentsDirectory.appendingPathComponent("\(segmentName).lex")
    guard
      let text = try? String(contentsOf: lexURL, encoding: .utf8)
    else {
      return [:]
    }
    let entries = text.components(separatedBy: .newlines).compactMap { line
      -> (term: String, offset: Int, byteLength: Int, docFrequency: Int)? in
      guard !line.isEmpty else {
        return nil
      }
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 4 else {
        return nil
      }
      return (
        parts[0],
        Int(parts[1]) ?? 0,
        Int(parts[2]) ?? 0,
        Int(parts[3]) ?? 0
      )
    }
    guard
      !entries.isEmpty,
      let handle = try? FileHandle(
        forReadingFrom: segmentsDirectory.appendingPathComponent(
          "\(segmentName).post"))
    else {
      return [:]
    }
    defer {
      try? handle.close()
    }

    var result: [String: Set<Int>] = [:]
    for entry in entries {
      handle.seek(toFileOffset: UInt64(entry.offset))
      let data = handle.readData(ofLength: entry.byteLength)
      result[entry.term] = Set(decodePostings(data, count: entry.docFrequency))
    }
    return result
  }

  private func postings(for term: String, segmentName: String) -> Set<Int> {
    guard
      let entry = lexEntry(for: term, segmentName: segmentName),
      let handle = try? FileHandle(
        forReadingFrom: segmentsDirectory.appendingPathComponent(
          "\(segmentName).post"))
    else {
      return []
    }
    defer {
      try? handle.close()
    }
    handle.seek(toFileOffset: UInt64(entry.offset))
    let data = handle.readData(ofLength: entry.byteLength)
    return Set(decodePostings(data, count: entry.docFrequency))
  }

  private func lexEntry(
    for term: String,
    segmentName: String
  ) -> (offset: Int, byteLength: Int, docFrequency: Int)? {
    let lexURL = segmentsDirectory.appendingPathComponent("\(segmentName).lex")
    guard
      let text = try? String(contentsOf: lexURL, encoding: .utf8)
    else {
      return nil
    }
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      let parts = line.components(separatedBy: "\t")
      if parts.count >= 4, parts[0] == term {
        return (
          Int(parts[1]) ?? 0,
          Int(parts[2]) ?? 0,
          Int(parts[3]) ?? 0
        )
      }
    }
    return nil
  }

  private func decodePostings(_ data: Data, count: Int) -> [Int] {
    var ids: [Int] = []
    var index = data.startIndex
    var previous = 0
    while index < data.endIndex && ids.count < count {
      let delta = Int(readVarint(data, index: &index))
      let id = previous + delta
      ids.append(id)
      previous = id
    }
    return ids
  }

  private func matches(
    _ document: MailIndexDocument,
    filters: [String: Any]
  ) -> Bool {
    func contains(_ field: String, _ key: String) -> Bool {
      guard let value = filters[key] as? String, !value.isEmpty else {
        return true
      }
      return field.localizedCaseInsensitiveContains(value)
    }
    return contains(document.sender, "from") &&
      contains(document.recipients, "to") &&
      contains(document.cc, "cc") &&
      contains(document.mailboxPath, "folder") &&
      contains(document.status, "status") &&
      contains(document.dateReceived + " " + document.dateSent, "date")
  }

  private func segmentNames() -> [String] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: segmentsDirectory,
        includingPropertiesForKeys: nil)
    else {
      return []
    }
    return files
      .filter { $0.pathExtension == "lex" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()
  }

  private func segmentNamesForMerge(from names: [String]) -> [String] {
    Array(
      names
        .map { ($0, segmentByteSize(name: $0)) }
        .sorted {
          if $0.1 != $1.1 {
            return $0.1 < $1.1
          }
          return $0.0 < $1.0
        }
        .prefix(Self.mergeFanIn)
        .map { $0.0 })
  }

  private func segmentByteSize(name: String) -> UInt64 {
    let lexSize = fileSize(
      at: segmentsDirectory.appendingPathComponent("\(name).lex"))
    let postSize = fileSize(
      at: segmentsDirectory.appendingPathComponent("\(name).post"))
    return lexSize + postSize
  }

  private func fileSize(at url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func derivedNextSegmentId() -> Int {
    let maxSegment = segmentNames()
      .compactMap { Int($0.replacingOccurrences(of: "seg-", with: "")) }
      .max() ?? 0
    return maxSegment + 1
  }

  private func appendText(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else {
      return
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else {
      return
    }
    defer {
      try? handle.close()
    }
    handle.seekToEndOfFile()
    handle.write(data)
  }

  private func atomicWrite(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else {
      return
    }
    atomicWrite(data, to: url)
  }

  private func atomicWrite(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let tempURL = url.deletingLastPathComponent().appendingPathComponent(
      "\(url.lastPathComponent).tmp")
    do {
      try data.write(to: tempURL, options: [.atomic])
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      try FileManager.default.moveItem(at: tempURL, to: url)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }

  private func appendVarint(_ value: UInt32, to data: inout Data) {
    var current = value
    while current >= 0x80 {
      let byte = UInt8(current & 0x7f) | UInt8(0x80)
      data.append(byte)
      current >>= 7
    }
    data.append(UInt8(current))
  }

  private func readVarint(_ data: Data, index: inout Data.Index) -> UInt32 {
    var shift: UInt32 = 0
    var value: UInt32 = 0
    while index < data.endIndex {
      let byte = data[index]
      index = data.index(after: index)
      value |= UInt32(byte & 0x7f) << shift
      if (byte & 0x80) == 0 {
        break
      }
      shift += 7
    }
    return value
  }
}

private enum MailIndexTokenizer {
  static func terms(for document: MailIndexDocument) -> Set<String> {
    var terms = Set<String>()
    addTerms(from: document.subject, to: &terms)
    addTerms(from: document.sender, to: &terms)
    addTerms(from: document.recipients, to: &terms)
    addTerms(from: document.cc, to: &terms)
    addTerms(from: document.account, to: &terms)
    addTerms(from: document.mailboxPath, to: &terms)
    addTerms(from: document.dateSent, to: &terms)
    addTerms(from: document.dateReceived, to: &terms)
    addEmailTerms(from: document.sender, prefix: "from", to: &terms)
    addEmailTerms(from: document.recipients, prefix: "to", to: &terms)
    addEmailTerms(from: document.cc, prefix: "cc", to: &terms)
    if !document.mailboxPath.isEmpty {
      terms.insert("folder:\(normalize(document.mailboxPath))")
    }
    if !document.taxonomyPath.isEmpty {
      addTerms(from: document.taxonomyPath, to: &terms)
      terms.insert("taxonomy:\(normalize(document.taxonomyPath))")
    }
    if !document.status.isEmpty {
      terms.insert("status:\(document.status.lowercased())")
    }
    return terms
  }

  static func terms(for query: String) -> Set<String> {
    var terms = Set<String>()
    addTerms(from: query, to: &terms)
    addEmailTerms(from: query, prefix: "person", to: &terms)
    return terms
  }

  private static func addTerms(from raw: String, to terms: inout Set<String>) {
    let lowered = raw.lowercased()
    var current = ""
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95 {
        current.unicodeScalars.append(scalar)
      } else {
        flushAscii(&current, to: &terms)
      }
    }
    flushAscii(&current, to: &terms)
    addCJKBigrams(from: lowered, to: &terms)
  }

  private static func addEmailTerms(
    from raw: String,
    prefix: String,
    to terms: inout Set<String>
  ) {
    let separators = CharacterSet(charactersIn: " ,;<>\"'()[]\n\r\t")
    for token in raw.lowercased().components(separatedBy: separators) {
      guard token.contains("@") else {
        continue
      }
      let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
      guard !cleaned.isEmpty else {
        continue
      }
      terms.insert(cleaned)
      terms.insert("\(prefix):\(cleaned)")
      terms.insert("person:\(cleaned)")
      if let domain = cleaned.split(separator: "@").last {
        terms.insert(String(domain))
        terms.insert("domain:\(domain)")
      }
    }
  }

  private static func flushAscii(_ current: inout String, to terms: inout Set<String>) {
    if current.count >= 2 {
      terms.insert(current)
    }
    current = ""
  }

  private static func addCJKBigrams(from raw: String, to terms: inout Set<String>) {
    let scalars = Array(raw.unicodeScalars.filter { scalar in
      (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
        (0x3400...0x4DBF).contains(Int(scalar.value))
    })
    guard scalars.count >= 2 else {
      return
    }
    for index in 0..<(scalars.count - 1) {
      terms.insert(String(String.UnicodeScalarView([scalars[index], scalars[index + 1]])))
    }
  }

  private static func normalize(_ raw: String) -> String {
    raw.lowercased()
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }
}

private struct MailIndexTaxonomyRule {
  let path: String
  let keywords: [String]
  let domains: [String]
}

private enum MailIndexTaxonomy {
  static let fallbackRules: [MailIndexTaxonomyRule] = [
    MailIndexTaxonomyRule(path: "开发/客户端/macOS", keywords: ["macos", "swift", "swiftui", "appkit", "xcode", "notarization", "签名"], domains: []),
    MailIndexTaxonomyRule(path: "开发/客户端/iOS", keywords: ["ios", "iphone app", "ipad", "app store", "testflight", "swiftui"], domains: []),
    MailIndexTaxonomyRule(path: "开发/前端/Web", keywords: ["frontend", "react", "nextjs", "vite", "typescript", "css", "html"], domains: []),
    MailIndexTaxonomyRule(path: "开发/后端/API", keywords: ["backend", "server", "api", "database", "postgres", "redis", "docker"], domains: []),
    MailIndexTaxonomyRule(path: "开发/AI/模型", keywords: ["openai", "gpt", "llm", "embedding", "rag", "model", "ai"], domains: ["openai.com", "github.com"]),
    MailIndexTaxonomyRule(path: "测试/自动化/E2E", keywords: ["test", "testing", "playwright", "selenium", "e2e", "自动化", "测试"], domains: []),
    MailIndexTaxonomyRule(path: "测试/质量/性能", keywords: ["performance", "benchmark", "latency", "profiling", "性能", "压测"], domains: []),
    MailIndexTaxonomyRule(path: "交付/发布/上线", keywords: ["release", "deploy", "deployment", "launch", "上线", "发布", "交付"], domains: []),
    MailIndexTaxonomyRule(path: "交付/作业/提交", keywords: ["assignment", "submission", "homework", "deadline", "coursework", "作业", "提交"], domains: []),
    MailIndexTaxonomyRule(path: "运营/云服务/监控", keywords: ["cloud", "aws", "azure", "digitalocean", "monitoring", "alert", "incident"], domains: ["digitalocean.com", "amazonaws.com", "microsoft.com"]),
    MailIndexTaxonomyRule(path: "购物/电子产品/手机", keywords: ["iphone", "android phone", "smartphone", "手机"], domains: ["apple.com", "samsung.com"]),
    MailIndexTaxonomyRule(path: "购物/电子产品/电脑", keywords: ["macbook", "laptop", "surface", "pc", "computer", "电脑", "笔记本"], domains: ["apple.com", "microsoftstoreemail.com"]),
    MailIndexTaxonomyRule(path: "购物/电子产品/游戏设备", keywords: ["xbox", "playstation", "controller", "gaming pc", "steam deck"], domains: ["microsoftstoreemail.com", "playstation.com"]),
    MailIndexTaxonomyRule(path: "购物/服装/运动鞋服", keywords: ["nike", "adidas", "jordan", "shoes", "sneaker", "ultraboost", "air max", "服装"], domains: ["official.nike.com", "uk-news.adidas.com"]),
    MailIndexTaxonomyRule(path: "购物/美妆/护肤", keywords: ["beauty", "cosmetic", "skincare", "makeup", "美妆", "护肤"], domains: []),
    MailIndexTaxonomyRule(path: "购物/家电/厨房", keywords: ["appliance", "kitchen", "fridge", "washer", "vacuum", "家电", "厨房"], domains: []),
    MailIndexTaxonomyRule(path: "购物/宠物/用品", keywords: ["pet", "dog", "cat", "宠物"], domains: []),
    MailIndexTaxonomyRule(path: "购物/乐器/音乐设备", keywords: ["guitar", "piano", "midi", "audio interface", "presonus", "乐器"], domains: ["presonus.com"]),
    MailIndexTaxonomyRule(path: "账单/订阅/数字服务", keywords: ["subscription", "receipt", "invoice", "renewal", "billing", "账单", "订阅"], domains: ["email.apple.com", "netflix.com"]),
    MailIndexTaxonomyRule(path: "账单/支付/交易", keywords: ["payment", "purchase", "order", "paid", "transaction", "付款", "支付"], domains: []),
    MailIndexTaxonomyRule(path: "广告/促销/折扣", keywords: ["sale", "discount", "offer", "coupon", "deal", "flash sale", "折扣", "促销"], domains: []),
    MailIndexTaxonomyRule(path: "投资/金融/转账", keywords: ["bank", "finance", "investment", "stock", "crypto", "transfer", "western union", "投资", "转账"], domains: ["westernunion.com"]),
    MailIndexTaxonomyRule(path: "学习/语言/课程", keywords: ["course", "lesson", "teacher", "learning", "italki", "language", "课程", "学习"], domains: ["italki.com", "sendgrid.net"]),
    MailIndexTaxonomyRule(path: "旅行/交通/票务", keywords: ["ticket", "train", "flight", "hotel", "travel", "holiday", "旅行", "机票", "火车"], domains: ["thetrainline.com"]),
    MailIndexTaxonomyRule(path: "安全/账号/登录", keywords: ["security", "sign-in", "login", "verification", "password", "account", "安全", "验证", "登录"], domains: ["accountprotection.microsoft.com", "accounts.google.com", "id.apple.com"]),
    MailIndexTaxonomyRule(path: "娱乐/游戏/发行", keywords: ["game", "steam", "xbox", "play", "final fantasy", "elder scrolls", "blizzard", "游戏"], domains: ["steampowered.com", "steamcommunity.com", "square-enix.com", "blizzard.com", "ea.com", "elderscrollsonline.com"]),
    MailIndexTaxonomyRule(path: "娱乐/影视/流媒体", keywords: ["netflix", "movie", "series", "watch", "streaming", "影视"], domains: ["mailer.netflix.com", "netflix.com"]),
    MailIndexTaxonomyRule(path: "生活/分享/日常", keywords: ["newsletter", "weekly", "photo", "family", "life", "生活", "分享"], domains: []),
  ]

  static func signature(from vocabularyFile: URL) -> String {
    guard let data = try? Data(contentsOf: vocabularyFile), !data.isEmpty else {
      return "builtin:\(fallbackRules.count)"
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func loadRules(from vocabularyFile: URL) -> [MailIndexTaxonomyRule] {
    guard
      let data = try? Data(contentsOf: vocabularyFile),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = json["entries"] as? [[String: Any]]
    else {
      return fallbackRules
    }

    var mergedRules = fallbackRules
    var indexByPath = Dictionary(
      uniqueKeysWithValues: mergedRules.enumerated().map { ($0.element.path, $0.offset) })

    for entry in entries {
      let status = (entry["status"] as? String ?? "active").lowercased()
      let pathSegments = entry["pathSegments"] as? [String] ?? []
      let path = pathSegments
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "/")
      guard !path.isEmpty else {
        continue
      }

      if status == "retired" {
        if let existingIndex = indexByPath[path] {
          mergedRules.remove(at: existingIndex)
          indexByPath = Dictionary(
            uniqueKeysWithValues: mergedRules.enumerated().map {
              ($0.element.path, $0.offset)
            })
        }
        continue
      }

      guard status == "active" else {
        continue
      }
      let keywords = (entry["keywords"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let domains = (entry["domains"] as? [String] ?? [])
        .map {
          $0
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
        }
        .filter { !$0.isEmpty }
      let rule = MailIndexTaxonomyRule(
        path: path,
        keywords: keywords,
        domains: domains)
      if let existingIndex = indexByPath[path] {
        mergedRules[existingIndex] = rule
      } else {
        indexByPath[path] = mergedRules.count
        mergedRules.append(rule)
      }
    }

    return mergedRules.isEmpty ? fallbackRules : mergedRules
  }

  static func classify(
    subject: String,
    sender: String,
    mailboxPath: String,
    rules: [MailIndexTaxonomyRule]
  ) -> String {
    let haystack = "\(subject) \(sender) \(mailboxPath)".lowercased()
    let domain = emailDomain(from: sender)
    var bestPath = "未分类"
    var bestScore = 0

    for rule in rules {
      var score = 0
      for keyword in rule.keywords where haystack.contains(keyword.lowercased()) {
        score += keyword.count >= 6 ? 3 : 2
      }
      for ruleDomain in rule.domains {
        let normalized = ruleDomain.lowercased()
        if domain == normalized || domain.hasSuffix(".\(normalized)") {
          score += 4
        } else if haystack.contains(normalized) {
          score += 3
        }
      }
      if score > bestScore {
        bestScore = score
        bestPath = rule.path
      }
    }

    return bestPath
  }

  private static func emailDomain(from raw: String) -> String {
    let separators = CharacterSet(charactersIn: " ,;<>\"'()[]\n\r\t")
    for token in raw.lowercased().components(separatedBy: separators) {
      guard token.contains("@") else {
        continue
      }
      let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
      if let domain = cleaned.split(separator: "@").last {
        return String(domain)
      }
    }
    return ""
  }
}

enum MacOSMailImporterError: Error, CustomStringConvertible {
  case scriptCompilationFailed
  case scriptFailed(String)
  case mailLaunchFailed(String)
  case badArguments(String)

  var description: String {
    switch self {
    case .scriptCompilationFailed:
      return "无法编译 Mail.app 导入脚本。"
    case .scriptFailed(let message):
      return message
    case .mailLaunchFailed(let message):
      return "无法启动 Mail.app：\(message)"
    case .badArguments(let message):
      return message
    }
  }
}

#if !canImport(FlutterMacOS)
extension MacOSMailImporter {
  static func commandLineAuthorizationPayload() throws -> [String: Any] {
    try requestAuthorization()
  }

  func commandLineExportPayload(mailWorkspaceDirectory: String) throws -> [String: Any] {
    try exportAllMessages(mailWorkspaceDirectory: mailWorkspaceDirectory)
  }
}

@main
struct LicoMacOSMailTool {
  static func main() {
    let status = run(arguments: Array(CommandLine.arguments.dropFirst()))
    Foundation.exit(Int32(status))
  }

  private static func run(arguments: [String]) -> Int {
    guard let command = arguments.first else {
      return fail("missing command")
    }
    let rest = Array(arguments.dropFirst())

    do {
      switch command {
      case "auth", "authorize", "authorization":
        return runOnWorker {
          try MacOSMailImporter.commandLineAuthorizationPayload()
        }
      case "export", "import":
        let workspace = try workspaceArgument(rest)
        return runOnWorker {
          try MacOSMailImporter().commandLineExportPayload(
            mailWorkspaceDirectory: workspace)
        }
      case "stats":
        let workspace = try workspaceArgument(rest)
        return output(indexStore(workspace: workspace).statsPayload())
      case "rebuild":
        let workspace = try workspaceArgument(rest)
        return output(indexStore(workspace: workspace).rebuildPayload())
      case "search":
        let workspace = try workspaceArgument(rest)
        let query = optionValue(rest, "--query") ?? firstPositional(rest, skipping: [workspace]) ?? ""
        let limit = intOption(rest, "--limit", defaultValue: 50)
        let offset = intOption(rest, "--offset", defaultValue: 0)
        return output(
          indexStore(workspace: workspace).searchPayload(
            query: query,
            filters: [:],
            limit: max(1, min(limit, 200)),
            offset: max(0, offset)))
      case "open":
        let workspace = try workspaceArgument(rest)
        let docId = optionValue(rest, "--doc-id").flatMap(Int.init)
        let messageKey = optionValue(rest, "--message-key")
        guard
          let payload = indexStore(workspace: workspace).openPayload(
            docId: docId,
            messageKey: messageKey)
        else {
          throw MacOSMailImporterError.badArguments("找不到索引邮件。")
        }
        return output(payload)
      case "pause":
        let workspace = try workspaceArgument(rest)
        return output(try writeControlFile(workspace: workspace, name: "control.pause", value: "paused"))
      case "resume":
        let workspace = try workspaceArgument(rest)
        return output(try removeControlFile(workspace: workspace, name: "control.pause"))
      case "cancel":
        let workspace = try workspaceArgument(rest)
        _ = try removeControlFile(workspace: workspace, name: "control.pause")
        return output(try writeControlFile(workspace: workspace, name: "control.cancel", value: "cancelled"))
      case "status":
        let workspace = try workspaceArgument(rest)
        return output(statusPayload(workspace: workspace))
      default:
        return fail("unknown command: \(command)")
      }
    } catch {
      return fail(String(describing: error))
    }
  }

  private static func runOnWorker(_ operation: @escaping () throws -> [String: Any]) -> Int {
    let semaphore = DispatchSemaphore(value: 0)
    var payload: [String: Any]?
    var failure: Error?
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        payload = try operation()
      } catch {
        failure = error
      }
      semaphore.signal()
    }
    semaphore.wait()
    if let failure {
      return fail(String(describing: failure))
    }
    return output(payload ?? [:])
  }

  private static func workspaceArgument(_ arguments: [String]) throws -> String {
    if let value = optionValue(arguments, "--workspace") ?? optionValue(arguments, "--mail-workspace") {
      return value
    }
    if let first = arguments.first, !first.hasPrefix("--") {
      return first
    }
    throw MacOSMailImporterError.badArguments("缺少 Mail.app 工作空间目录。")
  }

  private static func firstPositional(_ arguments: [String], skipping skippedValues: [String]) -> String? {
    var skipNext = false
    for value in arguments {
      if skipNext {
        skipNext = false
        continue
      }
      if value.hasPrefix("--") {
        skipNext = true
        continue
      }
      if skippedValues.contains(value) {
        continue
      }
      return value
    }
    return nil
  }

  private static func optionValue(_ arguments: [String], _ name: String) -> String? {
    for index in arguments.indices {
      let value = arguments[index]
      if value == name, index + 1 < arguments.count {
        return arguments[index + 1]
      }
      let prefix = "\(name)="
      if value.hasPrefix(prefix) {
        return String(value.dropFirst(prefix.count))
      }
    }
    return nil
  }

  private static func intOption(_ arguments: [String], _ name: String, defaultValue: Int) -> Int {
    optionValue(arguments, name).flatMap(Int.init) ?? defaultValue
  }

  private static func indexStore(workspace: String) -> MailIndexStore {
    let base = URL(fileURLWithPath: workspace)
    return MailIndexStore(
      baseDirectory: base.appendingPathComponent("index", isDirectory: true),
      downloadsDirectory: base.appendingPathComponent("downloads", isDirectory: true),
      manifestFile: base.appendingPathComponent("dedupe-manifest.tsv"))
  }

  private static func statusPayload(workspace: String) -> [String: Any] {
    let base = URL(fileURLWithPath: workspace)
    let tmp = base.appendingPathComponent("tmp", isDirectory: true)
    var payload = indexStore(workspace: workspace).statsPayload()
    payload["workspaceDirectory"] = base.path
    payload["downloadsDirectory"] = base.appendingPathComponent("downloads", isDirectory: true).path
    payload["tmpDirectory"] = tmp.path
    payload["paused"] = FileManager.default.fileExists(
      atPath: tmp.appendingPathComponent("control.pause").path)
    payload["cancelRequested"] = FileManager.default.fileExists(
      atPath: tmp.appendingPathComponent("control.cancel").path)
    if let progress = latestProgressPayload(
      from: tmp.appendingPathComponent("progress.tsv"),
      exportDirectory: base.appendingPathComponent("downloads", isDirectory: true))
    {
      payload["latestProgress"] = progress
    }
    if
      let data = try? Data(contentsOf: tmp.appendingPathComponent("diagnostics.json")),
      let diagnostics = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      payload["diagnostics"] = diagnostics
    }
    return payload
  }

  private static func latestProgressPayload(from file: URL, exportDirectory: URL) -> [String: Any]? {
    guard
      let text = try? String(contentsOf: file, encoding: .utf8),
      let line = text.components(separatedBy: .newlines).last(where: { !$0.isEmpty })
    else {
      return nil
    }
    let parts = line.components(separatedBy: "\t")
    guard parts.count >= 8 else {
      return nil
    }
    var payload: [String: Any] = [
      "kind": parts[0],
      "sequence": Int(parts[1]) ?? 0,
      "totalCount": Int(parts[2]) ?? 0,
      "exportedCount": Int(parts[3]) ?? 0,
      "failedCount": Int(parts[4]) ?? 0,
      "skippedCount": Int(parts[5]) ?? 0,
      "title": parts[6],
      "detail": parts[7],
      "exportDirectory": exportDirectory.path,
    ]
    let keys = [
      "messageKey", "account", "mailboxPath", "sender", "recipients", "cc",
      "dateSent", "dateReceived", "fileName", "sourceHash", "byteSize", "error",
      "status",
    ]
    for (offset, key) in keys.enumerated() where parts.count > offset + 8 {
      if key == "byteSize" {
        payload[key] = Int(parts[offset + 8]) ?? 0
      } else {
        payload[key] = parts[offset + 8]
      }
    }
    return payload
  }

  private static func writeControlFile(
    workspace: String,
    name: String,
    value: String
  ) throws -> [String: Any] {
    let tmp = URL(fileURLWithPath: workspace).appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent(name)
    try value.write(to: file, atomically: true, encoding: .utf8)
    return ["ok": true, "path": file.path]
  }

  private static func removeControlFile(workspace: String, name: String) throws -> [String: Any] {
    let file = URL(fileURLWithPath: workspace)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
    return ["ok": true, "path": file.path]
  }

  private static func output(_ payload: [String: Any]) -> Int {
    var normalized = payload
    normalized["ok"] = normalized["ok"] ?? true
    do {
      let data = try JSONSerialization.data(
        withJSONObject: normalized,
        options: [.prettyPrinted, .sortedKeys])
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return 0
    } catch {
      return fail(String(describing: error))
    }
  }

  private static func fail(_ message: String) -> Int {
    let payload: [String: Any] = [
      "ok": false,
      "error": message,
    ]
    if
      let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys])
    {
      FileHandle.standardError.write(data)
      FileHandle.standardError.write(Data("\n".utf8))
    } else {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
    return 1
  }
}
#endif
