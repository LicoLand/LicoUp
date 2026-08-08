import Flutter
import Security
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLocalOnlyTreeIsExcludedFromBackup() throws {
    let fileManager = FileManager.default
    let productRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent(LocalOnlyDataProtection.productDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: productRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: productRoot.deletingLastPathComponent()) }

    let portableRoot = productRoot.appendingPathComponent(
      LocalOnlyDataProtection.portableDataDirectoryName,
      isDirectory: true
    )
    let secureMeshRoot = productRoot.appendingPathComponent(
      LocalOnlyDataProtection.secureMeshDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: portableRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secureMeshRoot, withIntermediateDirectories: true)
    let canary = portableRoot.appendingPathComponent("backup-canary.json")
    try Data("local-only".utf8).write(to: canary)

    try LocalOnlyDataProtection.hardenTree(productRoot, fileManager: fileManager)

    for item in [productRoot, portableRoot, secureMeshRoot, canary] {
      XCTAssertTrue(try LocalOnlyDataProtection.isExcludedFromBackup(item))
    }
  }

  func testAtomicReplacementRequiresAndAcceptsReprotection() throws {
    let fileManager = FileManager.default
    let productRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent(LocalOnlyDataProtection.productDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: productRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: productRoot.deletingLastPathComponent()) }

    let file = productRoot.appendingPathComponent("atomic-canary.json")
    try Data("first".utf8).write(to: file, options: .atomic)
    try LocalOnlyDataProtection.protectLocalItem(
      file,
      under: productRoot,
      fileManager: fileManager
    )
    try Data("second".utf8).write(to: file, options: .atomic)
    try LocalOnlyDataProtection.protectLocalItem(
      file,
      under: productRoot,
      fileManager: fileManager
    )

    XCTAssertTrue(try LocalOnlyDataProtection.isExcludedFromBackup(file))
  }

  func testLocalOnlyProtectionRejectsSymlink() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    let link = root.appendingPathComponent("link")
    try Data("local-only".utf8).write(to: target)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertThrowsError(
      try LocalOnlyDataProtection.protectLocalItem(
        link,
        under: root,
        fileManager: fileManager
      )
    )
  }

  func testObsoletePortableRootIsExcludedWithoutImportingState() throws {
    let fileManager = FileManager.default
    let applicationSupportRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let obsoleteRoot = applicationSupportRoot.appendingPathComponent(
      LocalOnlyDataProtection.portableDataDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: obsoleteRoot, withIntermediateDirectories: true)
    let canary = obsoleteRoot.appendingPathComponent("must-not-be-imported")
    try Data("opaque".utf8).write(to: canary)
    defer { try? fileManager.removeItem(at: applicationSupportRoot) }

    XCTAssertTrue(
      try LocalOnlyDataProtection.excludeObsoletePortableDataRootFromBackup(
        applicationSupportRoot: applicationSupportRoot,
        fileManager: fileManager
      )
    )
    XCTAssertTrue(try LocalOnlyDataProtection.isExcludedFromBackup(obsoleteRoot))
    XCTAssertTrue(fileManager.fileExists(atPath: canary.path))
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: applicationSupportRoot
          .appendingPathComponent(LocalOnlyDataProtection.productDirectoryName)
          .path
      )
    )
  }

  func testSecretDeletionFailsClosedForAuthenticationErrors() throws {
    let bridge = SecureMeshIosBridge()
    for status in [errSecUserCanceled, errSecAuthFailed] {
      XCTAssertThrowsError(
        try bridge.deleteMobileRelaySecretAccount(
          "test-account",
          deleteItem: { _ in status }
        )
      ) { error in
        XCTAssertEqual((error as NSError).code, Int(status))
      }
    }
  }

  func testMissingSecretDeletionIsIdempotent() throws {
    let bridge = SecureMeshIosBridge()
    XCTAssertNoThrow(
      try bridge.deleteMobileRelaySecretAccount(
        "missing-account",
        deleteItem: { _ in errSecItemNotFound }
      )
    )
  }

  func testSecretReadReturnsNilOnlyForItemNotFound() throws {
    let bridge = SecureMeshIosBridge()

    let secret = try bridge.readMobileRelaySecretFromStoredAccount(
      "missing-account",
      copyItem: { _, copied in
        copied.pointee = nil
        return errSecItemNotFound
      }
    )

    XCTAssertNil(secret)
  }

  func testSecretReadFailsClosedForKeychainErrors() throws {
    let bridge = SecureMeshIosBridge()
    for status in [
      errSecUserCanceled,
      errSecAuthFailed,
      errSecInteractionNotAllowed,
      errSecDecode
    ] {
      XCTAssertThrowsError(
        try bridge.readMobileRelaySecretFromStoredAccount(
          "protected-account",
          copyItem: { _, copied in
            copied.pointee = nil
            return status
          }
        )
      ) { error in
        XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(status))
      }
    }
  }

  func testSecretReadRejectsMalformedSuccessPayload() throws {
    let bridge = SecureMeshIosBridge()
    let malformedPayloads: [CFTypeRef] = [
      NSString(string: "not-data"),
      NSData(data: Data([0xff]))
    ]

    for payload in malformedPayloads {
      XCTAssertThrowsError(
        try bridge.readMobileRelaySecretFromStoredAccount(
          "corrupt-account",
          copyItem: { _, copied in
            copied.pointee = payload
            return errSecSuccess
          }
        )
      ) { error in
        XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(errSecDecode))
      }
    }
  }

  func testSecretReadReturnsUtf8Payload() throws {
    let bridge = SecureMeshIosBridge()

    let secret = try bridge.readMobileRelaySecretFromStoredAccount(
      "present-account",
      copyItem: { _, copied in
        copied.pointee = NSData(data: Data("opaque-secret".utf8))
        return errSecSuccess
      }
    )

    XCTAssertEqual(secret, "opaque-secret")
  }

  func testSecretWritePreservesExistingItemWhenUpdateFails() throws {
    let bridge = SecureMeshIosBridge()
    var addAttempted = false

    XCTAssertThrowsError(
      try bridge.writeMobileRelaySecret(
        "replacement-secret",
        storedAccount: "protected-account",
        updateItem: { _, _ in errSecUserCanceled },
        addItem: { _ in
          addAttempted = true
          return errSecSuccess
        }
      )
    ) { error in
      XCTAssertEqual((error as NSError).code, Int(errSecUserCanceled))
    }
    XCTAssertFalse(addAttempted)
  }

  func testSecretWriteAddsOnlyAfterVerifiedNotFound() throws {
    let bridge = SecureMeshIosBridge()
    var addAttempted = false

    XCTAssertNoThrow(
      try bridge.writeMobileRelaySecret(
        "new-secret",
        storedAccount: "new-account",
        updateItem: { query, _ in
          XCTAssertEqual(query[kSecAttrService as String] as? String, bridge.mobileRelaySecretService)
          return errSecItemNotFound
        },
        addItem: { query in
          addAttempted = true
          XCTAssertNotNil(query[kSecAttrAccessControl as String])
          return errSecSuccess
        }
      )
    )
    XCTAssertTrue(addAttempted)
  }

  func testSecretWriteResolvesConcurrentInsertWithoutDeleting() throws {
    let bridge = SecureMeshIosBridge()
    var updateStatuses: [OSStatus] = [errSecItemNotFound, errSecSuccess]
    var addCount = 0

    XCTAssertNoThrow(
      try bridge.writeMobileRelaySecret(
        "replacement-secret",
        storedAccount: "raced-account",
        updateItem: { _, _ in updateStatuses.removeFirst() },
        addItem: { _ in
          addCount += 1
          return errSecDuplicateItem
        }
      )
    )
    XCTAssertTrue(updateStatuses.isEmpty)
    XCTAssertEqual(addCount, 1)
  }

  func testSecretStoreUsesCurrentPolicyNamespace() {
    XCTAssertTrue(SecureMeshIosBridge().mobileRelaySecretService.hasSuffix(".v2"))
  }

  func testCallbackAccountingDoesNotClaimAuthorizationCompletion() {
    let context = SecureMeshIosSecretStoreCallbackContext(bridge: SecureMeshIosBridge())
    context.recordCallbackSecretRead(authenticationContextAttached: true)
    context.recordCallbackSecretReadFound()

    XCTAssertEqual(context.callbackSecretReadFoundCount, 1)
    XCTAssertEqual(context.systemAuthorizationAttemptCount, 0)
    XCTAssertFalse(context.systemAuthorizationCompleted)
    XCTAssertFalse(context.productionCallbackAuthReady)
  }

  func testSecretDeletionBindsCurrentServiceAndAccount() throws {
    let bridge = SecureMeshIosBridge()
    let account = "runner-tests:synthetic-account"
    var capturedQuery: [String: Any]?

    try bridge.deleteMobileRelaySecretAccount(
      account,
      deleteItem: { query in
        capturedQuery = query
        return errSecSuccess
      }
    )

    XCTAssertEqual(
      capturedQuery?[kSecClass as String] as? String,
      kSecClassGenericPassword as String
    )
    XCTAssertEqual(
      capturedQuery?[kSecAttrService as String] as? String,
      bridge.mobileRelaySecretService
    )
    XCTAssertEqual(capturedQuery?[kSecAttrAccount as String] as? String, account)
  }

}
