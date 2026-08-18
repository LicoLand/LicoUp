import Cocoa

/// Pure close-to-menu-bar decisions. XCTest covers this without touching Dock
/// activation policy or creating a live `NSStatusItem`.
enum MacStatusBarPresencePolicy {
  static let terminatesAfterLastWindowClosed = false

  static func allowWindowClose(isTerminating: Bool) -> Bool {
    isTerminating
  }

  static func activationPolicy(hiddenToStatusBar: Bool) -> NSApplication.ActivationPolicy {
    hiddenToStatusBar ? .accessory : .regular
  }

  static func shouldSilentStart(arguments: [String]) -> Bool {
    arguments.contains("--silent-start")
  }

  /// Another live process of this bundle should own the session.
  static func existingInstancePid(
    currentPid: pid_t,
    otherInstancePids: [pid_t]
  ) -> pid_t? {
    otherInstancePids.first { $0 != currentPid }
  }

  static let statusItemImageName = "MenuBarIcon"
  static let statusItemImagePointSize: CGFloat = 18
  static let statusItemImageIsTemplate = false
  /// The extra is created when the main window is born, not only on close.
  static let createsStatusItemAtLaunch = true

  static let statusItemImageVerticalOffset: CGFloat = 0

  static func statusItemImageSize(intrinsic: NSSize) -> NSSize {
    let height = statusItemImagePointSize
    guard intrinsic.height > 0 else {
      return NSSize(width: height, height: height)
    }
    return NSSize(
      width: height * (intrinsic.width / intrinsic.height),
      height: height
    )
  }

  static func statusItemImageCanvasSize(glyph: NSSize) -> NSSize {
    NSSize(
      width: glyph.width,
      height: glyph.height + statusItemImageVerticalOffset
    )
  }

  static func showTitle(appName: String, locale: Locale = .current) -> String {
    prefersChinese(locale) ? "显示\(appName)" : "Show \(appName)"
  }

  static func quitTitle(appName: String, locale: Locale = .current) -> String {
    prefersChinese(locale) ? "退出\(appName)" : "Quit \(appName)"
  }

  private static func prefersChinese(_ locale: Locale) -> Bool {
    if let languageCode = locale.languageCode, languageCode.hasPrefix("zh") {
      return true
    }
    return locale.identifier.lowercased().hasPrefix("zh")
  }
}

/// Hides the Flutter window to an `NSStatusItem`, drops the Dock icon via
/// accessory activation policy, and restores both on demand. Quit stays a
/// separate action (status-item menu or Cmd+Q while the app is frontmost).
final class MacStatusBarPresence: NSObject {
  static let shared = MacStatusBarPresence()

  /// Activate the already-running client and report that this process should
  /// exit before Flutter bootstrap (target scans, Agent CLI probes).
  static func yieldToExistingInstanceIfNeeded() -> Bool {
    guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
      return false
    }
    let currentPid = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
      .map { $0.processIdentifier }
    guard let pid = MacStatusBarPresencePolicy.existingInstancePid(
      currentPid: currentPid,
      otherInstancePids: others
    ) else {
      return false
    }
    if let existing = NSRunningApplication(processIdentifier: pid) {
      existing.unhide()
      existing.activate(options: [.activateIgnoringOtherApps])
    }
    return true
  }

  private(set) var isHiddenToStatusBar = false
  private(set) var isTerminating = false

  private weak var mainWindow: NSWindow?
  private var statusItem: NSStatusItem?
  private var pendingFullScreenHide = false

  var appName: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? "LicoUp"
  }

  func attach(mainWindow: NSWindow) {
    self.mainWindow = mainWindow
    ensureStatusItem()
  }

  func windowShouldClose(_ window: NSWindow) -> Bool {
    if MacStatusBarPresencePolicy.allowWindowClose(isTerminating: isTerminating) {
      return true
    }
    hideToStatusBar(window)
    return false
  }

  func hideToStatusBar(_ window: NSWindow) {
    if isTerminating {
      return
    }
    mainWindow = window
    ensureStatusItem()
    if window.styleMask.contains(.fullScreen) {
      pendingFullScreenHide = true
      window.toggleFullScreen(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
        guard let self, self.pendingFullScreenHide else { return }
        self.pendingFullScreenHide = false
        self.finishHide(window)
      }
      return
    }
    finishHide(window)
  }

  @objc func restoreMainWindow() {
    pendingFullScreenHide = false
    NSApp.setActivationPolicy(
      MacStatusBarPresencePolicy.activationPolicy(hiddenToStatusBar: false)
    )
    guard let window = mainWindow else {
      activateApplication()
      isHiddenToStatusBar = false
      return
    }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.makeKeyAndOrderFront(nil)
    activateApplication()
    isHiddenToStatusBar = false
  }

  @objc func quitApplication() {
    prepareToTerminate()
    NSApp.terminate(nil)
  }

  func prepareToTerminate() {
    isTerminating = true
    pendingFullScreenHide = false
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  private func finishHide(_ window: NSWindow) {
    window.orderOut(nil)
    NSApp.setActivationPolicy(
      MacStatusBarPresencePolicy.activationPolicy(hiddenToStatusBar: true)
    )
    isHiddenToStatusBar = true
  }

  private func ensureStatusItem() {
    if statusItem != nil {
      return
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = statusItemImage()
      button.image = image
      button.imageScaling = .scaleNone
      button.imagePosition = .imageOnly
      button.toolTip = appName
      button.setAccessibilityTitle(appName)
      button.target = self
      button.action = #selector(statusItemActivated(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      if let image {
        item.length = image.size.width
      }
    }
    item.menu = nil
    statusItem = item
  }

  @objc private func statusItemActivated(_ sender: Any?) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      popUpStatusMenu()
      return
    }
    restoreMainWindow()
  }

  private func popUpStatusMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    let showItem = NSMenuItem(
      title: MacStatusBarPresencePolicy.showTitle(appName: appName),
      action: #selector(restoreMainWindow),
      keyEquivalent: ""
    )
    showItem.target = self
    let quitItem = NSMenuItem(
      title: MacStatusBarPresencePolicy.quitTitle(appName: appName),
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(showItem)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitItem)
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func statusItemImage() -> NSImage? {
    guard
      let source = NSImage(named: MacStatusBarPresencePolicy.statusItemImageName)?.copy()
        as? NSImage
    else {
      return nil
    }
    let glyph = MacStatusBarPresencePolicy.statusItemImageSize(intrinsic: source.size)
    source.size = glyph
    let canvas = MacStatusBarPresencePolicy.statusItemImageCanvasSize(glyph: glyph)
    let scale: CGFloat = 2
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, Int((canvas.width * scale).rounded())),
        pixelsHigh: max(1, Int((canvas.height * scale).rounded())),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    source.draw(
      in: NSRect(x: 0, y: 0, width: glyph.width, height: glyph.height),
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: nil
    )
    NSGraphicsContext.restoreGraphicsState()
    let composed = NSImage(size: canvas)
    composed.addRepresentation(rep)
    composed.isTemplate = MacStatusBarPresencePolicy.statusItemImageIsTemplate
    return composed
  }

  private func activateApplication() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
