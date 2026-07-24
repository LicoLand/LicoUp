import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Must stay in sync with `AppleControlMetrics.topBarHeight` in Flutter.
  private let flutterTopBarHeight: CGFloat = 48

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    self.backgroundColor = .clear
    self.isOpaque = false
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 560)
    if self.frame.width < 1040 || self.frame.height < 720 {
      self.setContentSize(NSSize(width: 1040, height: 720))
      self.center()
    }

    // Concentric with the collapsed shell search circle:
    // R_window = searchButtonRadius (16) + edgeInset (8) = 24.
    let windowCornerRadius: CGFloat = 24
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.cornerRadius = windowCornerRadius
    flutterViewController.view.layer?.masksToBounds = true
    if #available(macOS 10.15, *) {
      flutterViewController.view.layer?.cornerCurve = .continuous
    }

    // Align now and after Flutter finishes its first layout passes. Do not hook
    // didUpdate — that fires far too often and still cannot fix a bad mapping.
    self.alignTrafficLightButtonsWithTabBar()
    DispatchQueue.main.async { [weak self] in
      self?.alignTrafficLightButtonsWithTabBar()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.alignTrafficLightButtonsWithTabBar()
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidResizeNotification(_:)),
      name: NSWindow.didResizeNotification,
      object: self
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidEndLiveResizeNotification(_:)),
      name: NSWindow.didEndLiveResizeNotification,
      object: self
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Window-chrome bridge for the Flutter shell's hidden-titlebar chrome:
    // hand in-flight drags to AppKit and offer deliberate zoom, mirroring the
    // native title-bar contract under the shell's control.
    let windowChromeChannel = FlutterMethodChannel(
      name: "licoup/window_chrome",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChromeChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "dragWindow":
        // performDrag runs a modal tracking loop that consumes the rest of
        // this mouse stream; Flutter keeps no further drag events, which is
        // the intended handoff.
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "toggleZoom":
        self.zoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  @objc private func windowDidResizeNotification(_ notification: Notification) {
    alignTrafficLightButtonsWithTabBar()
  }

  @objc private func windowDidEndLiveResizeNotification(
    _ notification: Notification
  ) {
    alignTrafficLightButtonsWithTabBar()
  }

  private func alignTrafficLightButtonsWithTabBar() {
    let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton,
      .miniaturizeButton,
      .zoomButton,
    ]
    guard
      let closeButton = self.standardWindowButton(.closeButton),
      let buttonContainer = closeButton.superview,
      let contentView = self.contentView
    else {
      return
    }

    buttonContainer.layoutSubtreeIfNeeded()

    let buttonHeight = closeButton.frame.height
    // Equal top / bottom inset inside the Flutter-drawn top bar, and matching
    // left inset so the close light sits with equal left/top/bottom spacing.
    let inset = max((flutterTopBarHeight - buttonHeight) / 2.0, 0.0)

    // Map Flutter top-bar coordinates into the native traffic-light container.
    // Centering only inside the short native titlebar container leaves the
    // lights too high relative to the 48pt Flutter chrome.
    let desiredYInContent: CGFloat
    if contentView.isFlipped {
      desiredYInContent = inset
    } else {
      desiredYInContent = contentView.bounds.height - inset - buttonHeight
    }
    let desiredOriginInContent = NSPoint(x: inset, y: desiredYInContent)
    let originInContainer = buttonContainer.convert(
      desiredOriginInContent,
      from: contentView
    )

    let miniaturizeButton = self.standardWindowButton(.miniaturizeButton)
    let gap: CGFloat
    if let miniaturizeButton {
      gap = max(miniaturizeButton.frame.minX - closeButton.frame.maxX, 6)
    } else {
      gap = 6
    }

    var nextX = originInContainer.x
    let originY = originInContainer.y
    for buttonType in buttonTypes {
      guard let button = self.standardWindowButton(buttonType) else {
        continue
      }
      button.setFrameOrigin(NSPoint(x: nextX, y: originY))
      nextX = button.frame.maxX + gap
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
