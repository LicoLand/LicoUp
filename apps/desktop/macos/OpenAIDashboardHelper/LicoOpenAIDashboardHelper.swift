import AppKit
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import WebKit

enum DashboardHelperError: Error, CustomStringConvertible {
  case badArguments(String)
  case dashboardUnavailable(String)

  var description: String {
    switch self {
    case .badArguments(let message):
      return message
    case .dashboardUnavailable(let message):
      return message
    }
  }
}

@main
struct LicoOpenAIDashboardHelper {
  static let schemaVersion = "v0.0.1:openai-dashboard-helper-1"
  static let defaultURL = "https://chatgpt.com/codex/cloud/settings/analytics#usage"

  static func main() async {
    do {
      let arguments = parseArguments(Array(CommandLine.arguments.dropFirst()))
      guard let command = arguments.positionals.first else {
        throw DashboardHelperError.badArguments("lico-openai-dashboard-helper requires a command")
      }
      let payload: [String: Any]
      switch command {
      case "fetch":
        payload = try await fetch(arguments: arguments)
      default:
        throw DashboardHelperError.badArguments("unsupported lico-openai-dashboard-helper command: \(command)")
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

  @MainActor
  static func fetch(arguments: ParsedArguments) async throws -> [String: Any] {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let timeoutMs = intValue(arguments.value(for: "timeout-ms") ?? arguments.value(for: "timeoutMs")) ?? 12000
    let timeout = max(2000, timeoutMs)
    let rawURL = arguments.value(for: "url") ?? defaultURL
    guard let url = URL(string: rawURL) else {
      throw DashboardHelperError.badArguments("invalid dashboard URL")
    }
    let startedAt = Date()
    let explicitCookieHeader = try dashboardCookieHeader(arguments: arguments)
    var attempts: [[String: Any]] = []
    var candidates: [DashboardCookieCandidate] = []
    if let explicitCookieHeader, !explicitCookieHeader.isEmpty {
      candidates.append(DashboardCookieCandidate(
        label: "manual",
        cookies: DashboardProbe.cookies(from: explicitCookieHeader)))
    }
    if boolValue(arguments.value(for: "browser-cookie-import") ?? arguments.value(for: "browserCookieImport")) ?? false {
      let keychainSession = DashboardKeychainSession(interaction: keychainInteraction(arguments: arguments))
      candidates.append(contentsOf: await ChromiumDashboardCookieImporter(keychainSession: keychainSession).loadCandidates())
    }

    for candidate in candidates.prefix(8) {
      let remaining = timeout - Int(Date().timeIntervalSince(startedAt) * 1000)
      if remaining < 1800 { break }
      let probe = DashboardProbe(
        url: url,
        timeoutMs: min(remaining, max(2500, min(timeout, 6500))),
        cookieSource: candidate.label,
        cookies: candidate.cookies,
        usePersistentStore: false)
      let result = try await probe.run()
      attempts.append([
        "source": candidate.label,
        "status": result["status"] ?? "unknown",
        "cookieCount": candidate.cookies.count,
      ])
      if boolValue(result["ok"]) == true {
        return result
      }
    }

    let remaining = timeout - Int(Date().timeIntervalSince(startedAt) * 1000)
    let defaultProbe = DashboardProbe(
      url: url,
      timeoutMs: max(1800, min(remaining, timeout)),
      cookieSource: "webkit-default",
      cookies: [],
      usePersistentStore: true)
    var result = try await defaultProbe.run()
    if !attempts.isEmpty {
      result["attempts"] = attempts
    }
    return result
  }

  static func dashboardCookieHeader(arguments: ParsedArguments) throws -> String? {
    if let value = arguments.value(for: "cookie-header") ?? arguments.value(for: "cookieHeader"),
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return value
    }
    if let path = arguments.value(for: "cookie-header-file") ?? arguments.value(for: "cookieHeaderFile"),
       !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let env = ProcessInfo.processInfo.environment
    if let value = env["LICO_OPENAI_DASHBOARD_COOKIE_HEADER"],
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return value
    }
    return nil
  }

  static func keychainInteraction(arguments: ParsedArguments) -> DashboardKeychainInteraction {
    let env = ProcessInfo.processInfo.environment
    let raw = arguments.value(for: "keychain-interaction")
      ?? arguments.value(for: "keychainInteraction")
      ?? env["LICO_OPENAI_DASHBOARD_KEYCHAIN_INTERACTION"]
      ?? "none"
    return DashboardKeychainInteraction(rawValue: raw) ?? .none
  }

  static func printJson(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: payload,
      options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
  }
}

struct DashboardCookieCandidate {
  let label: String
  let cookies: [HTTPCookie]
}

private struct ChromiumCookieSource {
  let label: String
  let rootRelativePath: String
  let safeStorageLabels: [(service: String, account: String?)]
}

enum DashboardKeychainInteraction: String {
  case none
  case biometric
  case owner

  init?(rawValue: String) {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "0", "false", "off", "none", "no":
      self = .none
    case "biometric", "biometrics", "touchid", "touch-id", "fingerprint":
      self = .biometric
    case "owner", "device", "password", "any":
      self = .owner
    default:
      return nil
    }
  }
}

final class DashboardKeychainSession {
  private let interaction: DashboardKeychainInteraction
  private let context: LAContext
  private var prepared = false
  private var unavailable = false

  init(interaction: DashboardKeychainInteraction) {
    self.interaction = interaction
    self.context = LAContext()
    self.context.localizedReason = "Authorize browser cookies for OpenAI dashboard usage lookup."
    self.context.touchIDAuthenticationAllowableReuseDuration = 300
    if interaction == .none {
      self.context.interactionNotAllowed = true
    }
  }

  func password(service: String, account: String?) async -> String? {
    switch self.interaction {
    case .none:
      return self.queryPassword(service: service, account: account)
    case .biometric, .owner:
      guard await self.prepareInteractiveAccessIfNeeded() else { return nil }
      return self.queryPassword(service: service, account: account)
    }
  }

  private func prepareInteractiveAccessIfNeeded() async -> Bool {
    if self.prepared { return true }
    if self.unavailable { return false }
    let policy: LAPolicy = self.interaction == .biometric
      ? .deviceOwnerAuthenticationWithBiometrics
      : .deviceOwnerAuthentication
    var error: NSError?
    guard self.context.canEvaluatePolicy(policy, error: &error) else {
      self.unavailable = true
      return false
    }
    let ok = await withCheckedContinuation { continuation in
      self.context.evaluatePolicy(
        policy,
        localizedReason: "Authorize browser cookies for OpenAI dashboard usage lookup.")
      { success, _ in
        continuation.resume(returning: success)
      }
    }
    self.prepared = ok
    self.unavailable = !ok
    if ok {
      self.context.interactionNotAllowed = true
    }
    return ok
  }

  private func queryPassword(service: String, account: String?) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
      kSecUseAuthenticationContext as String: self.context,
    ]
    if let account, !account.isEmpty {
      query[kSecAttrAccount as String] = account
    }
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

private final class ChromiumDashboardCookieImporter {
  private static let sources: [ChromiumCookieSource] = [
    ChromiumCookieSource(
      label: "Chrome",
      rootRelativePath: "Library/Application Support/Google/Chrome",
      safeStorageLabels: [
        ("Chrome Safe Storage", "Chrome"),
        ("Chrome Safe Storage", nil),
      ]),
    ChromiumCookieSource(
      label: "Codex",
      rootRelativePath: "Library/Application Support/Codex",
      safeStorageLabels: [
        ("Codex Safe Storage", "Codex"),
        ("Codex Safe Storage", nil),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "Arc",
      rootRelativePath: "Library/Application Support/Arc/User Data",
      safeStorageLabels: [
        ("Arc Safe Storage", "Arc"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "Brave",
      rootRelativePath: "Library/Application Support/BraveSoftware/Brave-Browser",
      safeStorageLabels: [
        ("Brave Safe Storage", "Brave"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "Edge",
      rootRelativePath: "Library/Application Support/Microsoft Edge",
      safeStorageLabels: [
        ("Microsoft Edge Safe Storage", "Microsoft Edge"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "Chromium",
      rootRelativePath: "Library/Application Support/Chromium",
      safeStorageLabels: [
        ("Chromium Safe Storage", "Chromium"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "ChatGPT",
      rootRelativePath: "Library/Application Support/ChatGPT",
      safeStorageLabels: [
        ("ChatGPT Safe Storage", "ChatGPT"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
    ChromiumCookieSource(
      label: "Cursor",
      rootRelativePath: "Library/Application Support/Cursor",
      safeStorageLabels: [
        ("Cursor Safe Storage", "Cursor"),
        ("Chrome Safe Storage", "Chrome"),
      ]),
  ]

  private static let chromeEpochOffset: TimeInterval = 11_644_473_600
  private let fileManager = FileManager.default
  private let keychainSession: DashboardKeychainSession

  init(keychainSession: DashboardKeychainSession) {
    self.keychainSession = keychainSession
  }

  func loadCandidates() async -> [DashboardCookieCandidate] {
    let home = self.fileManager.homeDirectoryForCurrentUser
    var candidates: [DashboardCookieCandidate] = []
    for source in Self.sources {
      let root = home.appendingPathComponent(source.rootRelativePath, isDirectory: true)
      guard self.fileManager.fileExists(atPath: root.path) else { continue }
      let keys = await self.derivedKeys(for: source)
      for database in self.cookieDatabaseURLs(root: root).prefix(8) {
        let cookies = self.cookies(fromDatabase: database, source: source, keys: keys)
        guard self.hasSessionCookie(cookies) else { continue }
        let label = "\(source.label):\(self.profileLabel(for: database, root: root))"
        candidates.append(DashboardCookieCandidate(label: label, cookies: cookies))
      }
    }
    return candidates
  }

  private func cookieDatabaseURLs(root: URL) -> [URL] {
    var profiles = [root]
    if let entries = try? self.fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    {
      let ordered = entries.filter { url in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
          return false
        }
        let name = url.lastPathComponent
        return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("Guest") || name.hasPrefix("user-")
      }.sorted { lhs, rhs in
        Self.profileSortKey(lhs.lastPathComponent) < Self.profileSortKey(rhs.lastPathComponent)
      }
      profiles.append(contentsOf: ordered)
    }

    var databases: [URL] = []
    var seen = Set<String>()
    for profile in profiles {
      for database in [
        profile.appendingPathComponent("Cookies", isDirectory: false),
        profile.appendingPathComponent("Network/Cookies", isDirectory: false),
      ] {
        guard self.fileManager.fileExists(atPath: database.path), seen.insert(database.path).inserted else {
          continue
        }
        databases.append(database)
      }
    }
    return databases
  }

  private static func profileSortKey(_ name: String) -> String {
    if name == "Default" { return "000-\(name)" }
    if name.hasPrefix("Profile ") { return "100-\(name)" }
    return "200-\(name)"
  }

  private func cookies(
    fromDatabase database: URL,
    source: ChromiumCookieSource,
    keys: [Data])
    -> [HTTPCookie]
  {
    guard let copiedDatabase = self.copyCookieDatabase(database) else { return [] }
    defer { try? self.fileManager.removeItem(at: copiedDatabase) }

    var db: OpaquePointer?
    guard sqlite3_open_v2(copiedDatabase.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return []
    }
    defer { sqlite3_close(db) }

    let sql = """
      select host_key, name, path, expires_utc, is_secure, value, encrypted_value
      from cookies
      where host_key like '%chatgpt.com' or host_key like '%openai.com'
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    var cookies: [HTTPCookie] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let host = Self.text(statement, index: 0),
            let name = Self.text(statement, index: 1),
            let path = Self.text(statement, index: 2),
            !host.isEmpty,
            !name.isEmpty
      else {
        continue
      }
      let value = Self.text(statement, index: 5).flatMap { $0.isEmpty ? nil : $0 }
        ?? Self.blob(statement, index: 6).flatMap { Self.decrypt($0, usingAnyOf: keys) }
      guard let value, !value.isEmpty else { continue }

      let expires = Self.chromiumExpiry(sqlite3_column_int64(statement, 3))
      if let expires, expires < Date() { continue }
      let secure = sqlite3_column_int(statement, 4) != 0
      if let cookie = Self.makeCookie(
        domain: Self.normalizedDomain(host),
        name: name,
        path: path.isEmpty ? "/" : path,
        value: value,
        expires: expires,
        secure: secure)
      {
        cookies.append(cookie)
      }
    }
    return cookies
  }

  private func copyCookieDatabase(_ database: URL) -> URL? {
    let target = self.fileManager.temporaryDirectory
      .appendingPathComponent("lico-openai-cookie-\(UUID().uuidString).sqlite", isDirectory: false)
    do {
      try self.fileManager.copyItem(at: database, to: target)
      return target
    } catch {
      return nil
    }
  }

  private func profileLabel(for database: URL, root: URL) -> String {
    let profile = database.deletingLastPathComponent().lastPathComponent == "Network"
      ? database.deletingLastPathComponent().deletingLastPathComponent()
      : database.deletingLastPathComponent()
    let relative = profile.path.replacingOccurrences(of: "\(root.path)/", with: "")
    return relative == root.path ? "Root" : relative
  }

  private func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
    cookies.contains { cookie in
      let name = cookie.name.lowercased()
      return name.contains("session-token")
        || name.contains("authjs")
        || name.contains("next-auth")
        || name == "__session"
        || name == "_account"
    }
  }

  private func derivedKeys(for source: ChromiumCookieSource) async -> [Data] {
    var keys: [Data] = []
    var seen = Set<Data>()
    for label in source.safeStorageLabels {
      guard let password = await self.keychainSession.password(service: label.service, account: label.account) else {
        continue
      }
      let key = Self.deriveKey(from: password)
      if seen.insert(key).inserted {
        keys.append(key)
      }
    }
    return keys
  }

  private static func deriveKey(from password: String) -> Data {
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let keyLength = key.count
    _ = key.withUnsafeMutableBytes { keyBytes in
      password.utf8CString.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.bindMemory(to: Int8.self).baseAddress,
            passwordBytes.count - 1,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            keyBytes.bindMemory(to: UInt8.self).baseAddress,
            keyLength)
        }
      }
    }
    return key
  }

  private static func decrypt(_ encrypted: Data, usingAnyOf keys: [Data]) -> String? {
    for key in keys {
      if let value = Self.decrypt(encrypted, key: key) {
        return value
      }
    }
    return nil
  }

  private static func decrypt(_ encrypted: Data, key: Data) -> String? {
    guard encrypted.count > 3 else { return nil }
    let prefix = String(data: encrypted.prefix(3), encoding: .utf8)
    guard prefix == "v10" || prefix == "v11" else { return nil }
    let payload = Data(encrypted.dropFirst(3))
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var out = Data(count: payload.count + kCCBlockSizeAES128)
    let outCapacity = out.count
    var outLength = 0
    let status = out.withUnsafeMutableBytes { outBytes in
      payload.withUnsafeBytes { payloadBytes in
        key.withUnsafeBytes { keyBytes in
          iv.withUnsafeBytes { ivBytes in
            CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress,
              key.count,
              ivBytes.baseAddress,
              payloadBytes.baseAddress,
              payload.count,
              outBytes.baseAddress,
              outCapacity,
              &outLength)
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    out.count = outLength
    if let value = String(data: out, encoding: .utf8), !value.isEmpty {
      return value
    }
    if out.count > 32 {
      let trimmed = Data(out.dropFirst(32))
      if let value = String(data: trimmed, encoding: .utf8), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func makeCookie(
    domain: String,
    name: String,
    path: String,
    value: String,
    expires: Date?,
    secure: Bool)
    -> HTTPCookie?
  {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .domain: domain,
      .path: path,
      .name: name,
      .value: value,
    ]
    if secure {
      properties[.secure] = "TRUE"
    }
    if let expires {
      properties[.expires] = expires
    }
    return HTTPCookie(properties: properties)
  }

  private static func normalizedDomain(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return host }
    return trimmed
  }

  private static func chromiumExpiry(_ value: sqlite3_int64) -> Date? {
    guard value > 0 else { return nil }
    let seconds = (Double(value) / 1_000_000.0) - Self.chromeEpochOffset
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func text(_ statement: OpaquePointer, index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let raw = sqlite3_column_text(statement, index)
    else {
      return nil
    }
    return String(cString: raw)
  }

  private static func blob(_ statement: OpaquePointer, index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let raw = sqlite3_column_blob(statement, index)
    else {
      return nil
    }
    let size = Int(sqlite3_column_bytes(statement, index))
    guard size > 0 else { return nil }
    return Data(bytes: raw, count: size)
  }
}

@MainActor
final class DashboardProbe: NSObject, WKNavigationDelegate {
  private let url: URL
  private let timeoutMs: Int
  private let cookieSource: String
  private let cookies: [HTTPCookie]
  private let dataStore: WKWebsiteDataStore
  private let webView: WKWebView
  private var hostWindow: NSWindow?

  init(
    url: URL,
    timeoutMs: Int,
    cookieSource: String,
    cookies: [HTTPCookie],
    usePersistentStore: Bool)
  {
    self.url = url
    self.timeoutMs = timeoutMs
    self.cookieSource = cookieSource
    self.cookies = cookies
    self.dataStore = usePersistentStore ? WKWebsiteDataStore.default() : WKWebsiteDataStore.nonPersistent()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = self.dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 820), configuration: configuration)
    super.init()
    self.webView.navigationDelegate = self
  }

  func run() async throws -> [String: Any] {
    try await self.installCookiesIfNeeded()
    self.showOffscreenWindow()
    defer { self.closeOffscreenWindow() }

    var request = URLRequest(url: self.url)
    request.timeoutInterval = TimeInterval(max(2, self.timeoutMs / 1000))
    request.setValue("application/json,text/html,*/*", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("LicoArc", forHTTPHeaderField: "User-Agent")
    if let cookieHeader = Self.cookieHeader(for: self.cookies, requestHost: self.url.host), !cookieHeader.isEmpty {
      request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    }
    self.webView.load(request)

    let deadline = Date().addingTimeInterval(Double(self.timeoutMs) / 1000.0)
    var lastStatus: [String: Any] = [:]
    while Date() < deadline {
      try await Task.sleep(nanoseconds: 500_000_000)
      let status = try await self.scrape()
      lastStatus = status
      if let breakdown = status["usageBreakdown"] as? [[String: Any]], !breakdown.isEmpty {
        return [
          "ok": true,
          "schemaVersion": LicoOpenAIDashboardHelper.schemaVersion,
          "status": "ready",
          "source": "openai-dashboard-web",
          "cookieSource": self.cookieSource,
          "usageBreakdown": breakdown,
        ]
      }
      if boolValue(status["loginRequired"]) == true || boolValue(status["cloudflareInterstitial"]) == true {
        return [
          "ok": false,
          "schemaVersion": LicoOpenAIDashboardHelper.schemaVersion,
          "status": boolValue(status["cloudflareInterstitial"]) == true ? "blocked" : "login_required",
          "source": "openai-dashboard-web",
          "cookieSource": self.cookieSource,
        ]
      }
      if boolValue(status["workspacePicker"]) == true {
        continue
      }
    }

    return [
      "ok": false,
      "schemaVersion": LicoOpenAIDashboardHelper.schemaVersion,
      "status": "no_dashboard_data",
      "source": "openai-dashboard-web",
      "cookieSource": self.cookieSource,
      "debug": sanitizedDebug(lastStatus["usageBreakdownDebug"]),
    ]
  }

  private func installCookiesIfNeeded() async throws {
    guard !self.cookies.isEmpty else { return }
    let store = self.dataStore.httpCookieStore
    for cookie in self.cookies {
      await withCheckedContinuation { continuation in
        store.setCookie(cookie) {
          continuation.resume()
        }
      }
    }
  }

  static func cookies(from header: String) -> [HTTPCookie] {
    let parts = header
      .split(separator: ";")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var cookies: [HTTPCookie] = []
    for part in parts {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }
      let name = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(pair[1])
      guard !name.isEmpty else { continue }
      if let cookie = HTTPCookie(properties: [
        .domain: ".chatgpt.com",
        .path: "/",
        .name: name,
        .value: value,
        .secure: "TRUE",
      ]) {
        cookies.append(cookie)
      }
    }
    return cookies
  }

  private static func cookieHeader(for cookies: [HTTPCookie], requestHost: String?) -> String? {
    guard let requestHost, !cookies.isEmpty else { return nil }
    let host = requestHost.lowercased()
    let pairs = cookies.compactMap { cookie -> String? in
      let domain = cookie.domain
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
      guard host == domain || host.hasSuffix(".\(domain)") else { return nil }
      return "\(cookie.name)=\(cookie.value)"
    }
    guard !pairs.isEmpty else { return nil }
    return pairs.joined(separator: "; ")
  }

  private func showOffscreenWindow() {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
    let width = min(1200, visibleFrame.width)
    let height = min(1600, visibleFrame.height)
    let frame = NSRect(x: visibleFrame.maxX - 1, y: visibleFrame.maxY - 1, width: width, height: height)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.alphaValue = 0.001
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isExcludedFromWindowsMenu = true
    window.contentView = self.webView
    self.hostWindow = window
    window.orderFrontRegardless()
  }

  private func closeOffscreenWindow() {
    self.webView.stopLoading()
    self.webView.navigationDelegate = nil
    self.hostWindow?.orderOut(nil)
    self.hostWindow?.close()
    self.hostWindow = nil
  }

  private func scrape() async throws -> [String: Any] {
    let raw = try await self.webView.evaluateJavaScript(Self.scrapeScript)
    return raw as? [String: Any] ?? [:]
  }

  private static let scrapeScript = """
(() => {
  const textOf = el => {
    const raw = el && (el.innerText || el.textContent) ? String(el.innerText || el.textContent) : '';
    return raw.trim();
  };
  const parseHexColor = color => {
    if (!color) return null;
    const c = String(color).trim().toLowerCase();
    if (c.startsWith('#')) {
      if (c.length === 4) return '#' + c[1] + c[1] + c[2] + c[2] + c[3] + c[3];
      return c;
    }
    const m = c.match(/^rgba?\\(([^)]+)\\)$/);
    if (!m) return c;
    const parts = m[1].split(',').map(x => parseFloat(x.trim())).filter(Number.isFinite);
    if (parts.length < 3) return c;
    const toHex = n => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, '0');
    return '#' + toHex(parts[0]) + toHex(parts[1]) + toHex(parts[2]);
  };
  const reactPropsOf = el => {
    if (!el) return null;
    try {
      const keys = Object.keys(el);
      const propsKey = keys.find(k => k.startsWith('__reactProps$'));
      if (propsKey) return el[propsKey] || null;
      const fiberKey = keys.find(k => k.startsWith('__reactFiber$'));
      if (fiberKey) {
        const fiber = el[fiberKey];
        return (fiber && (fiber.memoizedProps || fiber.pendingProps)) || null;
      }
    } catch {}
    return null;
  };
  const reactFiberOf = el => {
    if (!el) return null;
    try {
      const fiberKey = Object.keys(el).find(k => k.startsWith('__reactFiber$'));
      return fiberKey ? (el[fiberKey] || null) : null;
    } catch { return null; }
  };
  const nestedBarMetaOf = root => {
    if (!root || typeof root !== 'object') return null;
    const queue = [root];
    const seen = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
    let steps = 0;
    while (queue.length && steps < 300) {
      const cur = queue.shift();
      steps++;
      if (!cur || typeof cur !== 'object') continue;
      if (seen) {
        if (seen.has(cur)) continue;
        seen.add(cur);
      }
      if (cur.payload && (cur.dataKey || cur.name || cur.value !== undefined)) return cur;
      const values = Array.isArray(cur) ? cur : Object.values(cur);
      for (const v of values) if (v && typeof v === 'object') queue.push(v);
    }
    return null;
  };
  const barMetaFromElement = el => {
    const direct = reactPropsOf(el);
    if (direct && direct.payload && (direct.dataKey || direct.name || direct.value !== undefined)) return direct;
    const fiber = reactFiberOf(el);
    if (fiber) {
      let cur = fiber;
      for (let i = 0; i < 10 && cur; i++) {
        const props = (cur.memoizedProps || cur.pendingProps) || null;
        if (props && props.payload && (props.dataKey || props.name || props.value !== undefined)) return props;
        const nested = props ? nestedBarMetaOf(props) : null;
        if (nested) return nested;
        cur = cur.return || null;
      }
    }
    return direct ? nestedBarMetaOf(direct) : null;
  };
  const localDayKeyForDate = date => {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  };
  const dayKeyFromPayload = payload => {
    if (!payload || typeof payload !== 'object') return null;
    for (const k of ['day', 'date', 'name', 'label', 'x', 'time', 'timestamp']) {
      const v = payload[k];
      if (typeof v === 'string') {
        const s = v.trim();
        if (/^\\d{4}-\\d{2}-\\d{2}$/.test(s)) return s;
        const iso = s.match(/^(\\d{4}-\\d{2}-\\d{2})/);
        if (iso) return iso[1];
      }
      if (typeof v === 'number' && Number.isFinite(v)) {
        const d = new Date(v);
        if (!isNaN(d.getTime())) return localDayKeyForDate(d);
      }
    }
    return null;
  };
  const isSkillUsageServiceKey = raw => String(raw ?? '').trim().toLowerCase().startsWith('skillusage:');
  const displayNameForUsageServiceKey = raw => {
    const key = String(raw ?? '').trim();
    if (!key || isSkillUsageServiceKey(key)) return null;
    if (key.toUpperCase() === key && key.length <= 6) return key;
    const lower = key.toLowerCase();
    if (lower === 'cli') return 'CLI';
    if (lower.includes('github') && lower.includes('review')) return 'GitHub Code Review';
    return lower.replace(/[_-]+/g, ' ').split(' ').filter(Boolean)
      .map(w => w.length <= 2 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
  };
  const isLikelyCodexUsageService = raw => {
    const service = String(raw ?? '').trim().toLowerCase();
    return service === 'cli' || service === 'desktop' || service === 'desktop app' ||
      service === 'vscode' || service === 'vs code' || service === 'unknown' ||
      (service.includes('github') && service.includes('review'));
  };
  const usageChartRootForPath = path => {
    if (!path || !path.closest) return null;
    return path.closest('.recharts-wrapper') || path.closest('svg.recharts-surface') ||
      path.closest('section') || path.parentElement || null;
  };
  const uniqueUsageChartRoots = paths => {
    const roots = [];
    for (const path of paths) {
      const root = usageChartRootForPath(path);
      if (root && !roots.includes(root)) roots.push(root);
    }
    return roots;
  };
  const usageBreakdownTitleScore = title => {
    const lower = String(title || '').trim().toLowerCase().replace(/\\s+/g, ' ');
    if (!lower) return 0;
    if (lower === 'usage breakdown') return 1000000;
    if (lower.includes('usage breakdown')) return 900000;
    if (lower === 'personal usage') return 800000;
    if (lower.includes('threads') || lower.includes('turns') || lower.includes('client') ||
      lower.includes('skill') || lower.includes('invocation')) return -1000000;
    return 0;
  };
  const titleLikeElements = scope => {
    try {
      return Array.from(scope.querySelectorAll('h1,h2,h3,[role="heading"],div,span,p'))
        .filter(el => {
          const title = textOf(el);
          const lower = title.toLowerCase();
          const tag = el.tagName ? el.tagName.toLowerCase() : '';
          const isHeading = tag === 'h1' || tag === 'h2' || tag === 'h3' ||
            String(el.getAttribute('role') || '').toLowerCase() === 'heading';
          return title.length > 0 && title.length <= 80 &&
            (isHeading || usageBreakdownTitleScore(title) !== 0 ||
              lower.includes('usage breakdown') || lower.includes('threads') ||
              lower.includes('turns') || lower.includes('client') ||
              lower.includes('skill') || lower.includes('invocation'));
        });
    } catch { return []; }
  };
  const titleNodePrecedesRoot = (titleNode, root) => {
    if (!titleNode || titleNode === root || root.contains(titleNode) || titleNode.contains(root)) return false;
    return Boolean(titleNode.compareDocumentPosition(root) & Node.DOCUMENT_POSITION_FOLLOWING);
  };
  const nearestChartTitleTextForRoot = root => {
    if (!root) return '';
    try {
      let ancestor = root.parentElement || null;
      for (let i = 0; i < 8 && ancestor; i++) {
        let best = null;
        for (const titleNode of titleLikeElements(ancestor)) {
          if (!titleNodePrecedesRoot(titleNode, root)) continue;
          const title = textOf(titleNode);
          const score = usageBreakdownTitleScore(title);
          if (score !== 0 && (!best || score >= best.score)) best = { title, score };
        }
        if (best) return best.title;
        ancestor = ancestor.parentElement || null;
      }
    } catch {}
    return '';
  };
  const legendMapForUsageChartRoot = root => {
    const legendMap = {};
    for (const scope of [root, root && root.parentElement, root && root.closest ? root.closest('section') : null].filter(Boolean)) {
      try {
        for (const item of Array.from(scope.querySelectorAll('div[title]'))) {
          const title = item.getAttribute('title') ? String(item.getAttribute('title')).trim() : '';
          const square = item.querySelector('div[style*="background-color"]');
          const color = square && square.style ? square.style.backgroundColor : null;
          const hex = parseHexColor(color);
          if (title && hex) legendMap[hex] = title;
        }
      } catch {}
      if (Object.keys(legendMap).length > 0) break;
    }
    return legendMap;
  };
  const parseUsageBreakdownFromChartPaths = (paths, legendMap) => {
    const totalsByDay = {};
    const addValue = (day, service, value) => {
      if (!day || !service || isSkillUsageServiceKey(service)) return false;
      if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return false;
      if (!totalsByDay[day]) totalsByDay[day] = {};
      totalsByDay[day][service] = (totalsByDay[day][service] || 0) + value;
      return true;
    };
    let pointCount = 0;
    for (const path of paths) {
      const meta = barMetaFromElement(path) || barMetaFromElement(path.parentElement) || null;
      if (!meta) continue;
      const payload = meta.payload || null;
      const day = dayKeyFromPayload(payload);
      if (!day) continue;
      const valuesObj = payload && payload.values && typeof payload.values === 'object' ? payload.values : null;
      if (valuesObj) {
        for (const [k, v] of Object.entries(valuesObj)) {
          if (addValue(day, displayNameForUsageServiceKey(k), v)) pointCount++;
        }
        continue;
      }
      let value = typeof meta.value === 'number' && Number.isFinite(meta.value) ? meta.value : null;
      if (value === null && typeof meta.value === 'string') {
        const parsed = parseFloat(meta.value.replace(/,/g, ''));
        if (Number.isFinite(parsed)) value = parsed;
      }
      if (value === null) continue;
      const fill = parseHexColor(meta.fill || path.getAttribute('fill'));
      const service = (fill && legendMap[fill]) || (typeof meta.name === 'string' && meta.name) || null;
      if (addValue(day, service, value)) pointCount++;
    }
    const dayKeys = Object.keys(totalsByDay)
      .filter(day => Object.keys(totalsByDay[day] || {}).length > 0)
      .sort((a, b) => b.localeCompare(a))
      .slice(0, 30);
    const breakdown = dayKeys.map(day => {
      const servicesMap = totalsByDay[day] || {};
      const services = Object.keys(servicesMap).map(service => ({ service, creditsUsed: servicesMap[service] }))
        .sort((a, b) => b.creditsUsed === a.creditsUsed ? a.service.localeCompare(b.service) : b.creditsUsed - a.creditsUsed);
      return { day, services, totalCreditsUsed: services.reduce((sum, s) => sum + (Number(s.creditsUsed) || 0), 0) };
    });
    const services = Array.from(new Set(breakdown.flatMap(day => day.services.map(service => service.service))));
    const totalCreditsUsed = breakdown.reduce((sum, day) => sum + (Number(day.totalCreditsUsed) || 0), 0);
    const likelyCodexServiceCount = services.filter(isLikelyCodexUsageService).length;
    return { breakdown, pointCount, services, totalCreditsUsed, likelyCodexServiceCount,
      score: likelyCodexServiceCount * 1000 + services.length * 100 + pointCount + totalCreditsUsed / 1000 };
  };
  const paths = Array.from(document.querySelectorAll('g.recharts-bar-rectangle path.recharts-rectangle'));
  const roots = uniqueUsageChartRoots(paths);
  const candidates = roots.map(root => {
    const chartPaths = paths.filter(path => usageChartRootForPath(path) === root);
    const title = nearestChartTitleTextForRoot(root);
    const titleScore = usageBreakdownTitleScore(title);
    const parsed = parseUsageBreakdownFromChartPaths(chartPaths, legendMapForUsageChartRoot(root));
    return { title, titleScore, pathCount: chartPaths.length, ...parsed, score: titleScore + parsed.score };
  }).filter(candidate => candidate.breakdown.length > 0);
  const eligibleCandidates = candidates.filter(candidate => candidate.titleScore > 0).sort((a, b) => b.score - a.score);
  const breakdown = eligibleCandidates[0] ? eligibleCandidates[0].breakdown : [];
  const bodyText = document.body ? String(document.body.innerText || '').trim() : '';
  const href = window.location ? String(window.location.href || '') : '';
  const lower = bodyText.toLowerCase();
  const hasAuthInputs = !!document.querySelector('input[type="email"],input[type="password"],input[name="username"]');
  const loginCTA = lower.includes('sign in') || lower.includes('log in') ||
    lower.includes('continue with google') || lower.includes('continue with apple') ||
    lower.includes('continue with microsoft');
  const title = document.title ? String(document.title || '') : '';
  const cloudflareInterstitial = title.toLowerCase().includes('just a moment') ||
    lower.includes('checking your browser') || lower.includes('cloudflare');
  const debug = {
    pathCount: paths.length,
    chartCount: roots.length,
    candidateCount: candidates.length,
    eligibleCandidateCount: eligibleCandidates.length,
    selectedCandidateTitle: eligibleCandidates[0] ? eligibleCandidates[0].title : null,
    candidates: candidates.slice(0, 4).map(candidate => ({
      title: candidate.title,
      titleScore: candidate.titleScore,
      pathCount: candidate.pathCount,
      dayCount: candidate.breakdown.length,
      serviceCount: candidate.services.length,
      services: candidate.services.slice(0, 8)
    }))
  };
  return {
    href,
    loginRequired: href.includes('/auth/') || href.includes('/login') ||
      (hasAuthInputs && loginCTA) || (!hasAuthInputs && loginCTA && href.includes('chatgpt.com')),
    workspacePicker: bodyText.includes('Select a workspace'),
    cloudflareInterstitial,
    usageBreakdown: breakdown,
    usageBreakdownDebug: JSON.stringify(debug)
  };
})();
"""
}

struct ParsedArguments {
  let positionals: [String]
  let options: [String: String]

  func value(for key: String) -> String? {
    options[key]
  }
}

func parseArguments(_ args: [String]) -> ParsedArguments {
  var positionals: [String] = []
  var options: [String: String] = [:]
  var index = 0
  while index < args.count {
    let arg = args[index]
    if arg.hasPrefix("--") {
      let key = String(arg.dropFirst(2))
      if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
        options[key] = args[index + 1]
        index += 2
      } else {
        options[key] = "true"
        index += 1
      }
    } else {
      positionals.append(arg)
      index += 1
    }
  }
  return ParsedArguments(positionals: positionals, options: options)
}

func intValue(_ value: String?) -> Int? {
  guard let value else { return nil }
  return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
}

func boolValue(_ value: Any?) -> Bool? {
  if let value = value as? Bool { return value }
  if let value = value as? NSNumber { return value.boolValue }
  if let value = value as? String {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
  }
  return nil
}

func sanitizedDebug(_ value: Any?) -> Any {
  guard let text = value as? String, !text.isEmpty else { return NSNull() }
  guard let data = text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) else {
    return NSNull()
  }
  return object
}
