import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 560)
    if self.frame.width < 1040 || self.frame.height < 720 {
      self.setContentSize(NSSize(width: 1040, height: 720))
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacOSMailImporter.register(with: flutterViewController)

    super.awakeFromNib()
  }
}
