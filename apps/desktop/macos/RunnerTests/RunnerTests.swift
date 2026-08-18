import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {
  func testCloseDoesNotQuitAndUsesAccessoryPolicy() {
    XCTAssertFalse(MacStatusBarPresencePolicy.terminatesAfterLastWindowClosed)
    XCTAssertFalse(MacStatusBarPresencePolicy.allowWindowClose(isTerminating: false))
    XCTAssertTrue(MacStatusBarPresencePolicy.allowWindowClose(isTerminating: true))
    XCTAssertEqual(
      MacStatusBarPresencePolicy.activationPolicy(hiddenToStatusBar: true),
      .accessory
    )
    XCTAssertEqual(
      MacStatusBarPresencePolicy.activationPolicy(hiddenToStatusBar: false),
      .regular
    )
  }

  func testSilentStartHonorsExistingAutostartFlag() {
    XCTAssertTrue(
      MacStatusBarPresencePolicy.shouldSilentStart(arguments: ["licoup", "--silent-start"])
    )
    XCTAssertFalse(
      MacStatusBarPresencePolicy.shouldSilentStart(arguments: ["licoup"])
    )
  }

  func testDuplicateLaunchYieldsToTheExistingPid() {
    XCTAssertNil(
      MacStatusBarPresencePolicy.existingInstancePid(
        currentPid: 10,
        otherInstancePids: [10]
      )
    )
    XCTAssertEqual(
      MacStatusBarPresencePolicy.existingInstancePid(
        currentPid: 10,
        otherInstancePids: [10, 22]
      ),
      22
    )
  }

  func testStatusItemUsesColoredMenuBarGlyph() {
    XCTAssertEqual(MacStatusBarPresencePolicy.statusItemImageName, "MenuBarIcon")
    XCTAssertEqual(MacStatusBarPresencePolicy.statusItemImagePointSize, 18)
    XCTAssertFalse(MacStatusBarPresencePolicy.statusItemImageIsTemplate)
    XCTAssertTrue(MacStatusBarPresencePolicy.createsStatusItemAtLaunch)
    let fitted = MacStatusBarPresencePolicy.statusItemImageSize(
      intrinsic: NSSize(width: 796, height: 921)
    )
    XCTAssertEqual(fitted.height, 18)
    XCTAssertEqual(fitted.width, 18 * (796 / 921), accuracy: 0.01)
    XCTAssertEqual(MacStatusBarPresencePolicy.statusItemImageVerticalOffset, 0)
    let canvas = MacStatusBarPresencePolicy.statusItemImageCanvasSize(glyph: fitted)
    XCTAssertEqual(canvas.width, fitted.width)
    XCTAssertEqual(canvas.height, 18)
  }

  func testStatusItemMenuTitlesUseExistingAppName() {
    XCTAssertEqual(
      MacStatusBarPresencePolicy.showTitle(appName: "LicoUp", locale: Locale(identifier: "en")),
      "Show LicoUp"
    )
    XCTAssertEqual(
      MacStatusBarPresencePolicy.quitTitle(appName: "LicoUp", locale: Locale(identifier: "en")),
      "Quit LicoUp"
    )
    XCTAssertEqual(
      MacStatusBarPresencePolicy.showTitle(appName: "LicoUp", locale: Locale(identifier: "zh-Hans")),
      "显示LicoUp"
    )
    XCTAssertEqual(
      MacStatusBarPresencePolicy.quitTitle(appName: "LicoUp", locale: Locale(identifier: "zh-Hans")),
      "退出LicoUp"
    )
  }
}
