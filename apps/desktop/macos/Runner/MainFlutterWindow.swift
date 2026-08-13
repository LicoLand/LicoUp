import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Must stay in sync with `AppleControlMetrics.topBarHeight` in Flutter.
  private let flutterTopBarHeight: CGFloat = 48

  /// Clears AppKit layer backgrounds so transparent Flutter pixels reveal
  /// the NSVisualEffectView beneath instead of the default black backing.
  private func applyTransparentLayer(to view: NSView) {
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
  }

  /// Installing the visual-effect view as `contentView` (below) makes AppKit
  /// clear `contentViewController`, which would deallocate the
  /// FlutterViewController and shut its engine (and the Dart VM) down. Retain
  /// the controller for the window's lifetime so the engine keeps rendering
  /// into its view inside the visual-effect hierarchy.
  private var retainedFlutterViewController: FlutterViewController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.retainedFlutterViewController = flutterViewController
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    flutterViewController.backgroundColor = .clear
    self.backgroundColor = .clear
    self.isOpaque = false
    if #available(macOS 11.0, *) {
      self.titlebarSeparatorStyle = .none
    }
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 560)
    if self.frame.width < 1040 || self.frame.height < 720 {
      self.setContentSize(NSSize(width: 1040, height: 720))
      self.center()
    }

    // Concentric with the collapsed shell search circle:
    // R_window = searchButtonRadius (16) + edgeInset (8) = 24.
    let windowCornerRadius: CGFloat = 24

    // True Dock-style frosted glass: a system visual-effect view behind the
    // Flutter content, so transparent Flutter regions (the Messaging
    // profile's window chrome) blur the desktop beneath the window while
    // opaque regions render unchanged. `.underWindowBackground` follows the
    // system appearance in both light and dark presets.
    let visualEffectView = NSVisualEffectView(
      frame: flutterViewController.view.frame
    )
    visualEffectView.autoresizingMask = [.width, .height]
    visualEffectView.material = .underWindowBackground
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active
    applyTransparentLayer(to: visualEffectView)
    visualEffectView.layer?.cornerRadius = windowCornerRadius
    visualEffectView.layer?.masksToBounds = true
    if #available(macOS 10.15, *) {
      visualEffectView.layer?.cornerCurve = .continuous
    }
    flutterViewController.view.autoresizingMask = [.width, .height]
    flutterViewController.view.frame = visualEffectView.bounds
    applyTransparentLayer(to: flutterViewController.view)
    // Corner shape is owned by the visual-effect view; the Flutter view stays
    // unclipped so transparent margin gutters do not expose a black layer.
    flutterViewController.view.layer?.cornerRadius = windowCornerRadius
    if #available(macOS 10.15, *) {
      flutterViewController.view.layer?.cornerCurve = .continuous
    }
    visualEffectView.addSubview(flutterViewController.view)
    self.contentView = visualEffectView
    applyTransparentLayer(to: self.contentView!)

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
