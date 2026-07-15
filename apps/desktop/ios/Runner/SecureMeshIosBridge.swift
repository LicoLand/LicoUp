import Flutter
import Darwin
import Foundation
import LocalAuthentication
import Security
import UIKit

final class SecureMeshIosBridge {
  static let channelName = "licolite.secure_mesh.ios"
  static let mobileRelaySecretOverrideTransport = "platform_keyring_to_rust_ffi_memory_override"
  static let mobileRelaySecretStoreContract = "rust_secure_mesh_secret_store_handle_v1"
  static let mobileRelaySecretStoreBackend = "ios-keychain"
  static let mobileRelaySecretStoreAccountPrefix = "mobileRelayE2ee"
  static let mobileRelaySecretStoreNamespace = "mobileRelayRuntime"

  static var bridge: SecureMeshIosBridge?
  static var channel: FlutterMethodChannel?

  let fileManager: FileManager
  let mobileRelaySecretService = "app.licoarc.mobile-relay.secret-store.v1"

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    let bridge = SecureMeshIosBridge()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      bridge.handle(call: call, result: result)
    }
    #if targetEnvironment(simulator)
      _ = bridge.writeLaunchRuntimeStatus()
    #endif
    bridge.prunePersistentDiagnostics()
    self.bridge = bridge
    self.channel = channel
  }

  static func setForegroundIdleTimerGuard(active: Bool) {
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = active
    }
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(status())
    case "writeRuntimeStatus":
      result(writeRuntimeStatus())
    case "nativeJson":
      result(nativeJson(call.arguments))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func status() -> [String: Any] {
    let keychain = keychainStatus()
    let localAuthentication = localAuthenticationStatus()
    let selfTestPassed = lico_secure_mesh_runtime_self_test() == 1
    let featureMask = lico_secure_mesh_runtime_feature_flags()
    let keychainReady = keychain["available"] as? Bool == true
    let nativeReady = selfTestPassed && keychainReady
    return [
      "ok": nativeReady,
      "protocolVersion": "licolite.secure-mesh.v1",
      "endpointKind": "mobile",
      "platform": "ios",
      "bridge": [
        "methodChannel": Self.channelName,
        "statusMethod": true,
        "writeRuntimeStatusMethod": true,
        "nativeJsonMethod": true
      ],
      "secureStore": keychain,
      "localAuthentication": localAuthentication,
      "nativeRuntime": [
        "provider": "lico-client-native",
        "ffiBoundary": "c-abi",
        "loaded": true,
        "selfTestPassed": selfTestPassed,
        "featureMask": Int(featureMask),
        "featureFlags": featureFlags(featureMask),
        "protocolHash": Int(lico_secure_mesh_runtime_protocol_hash()),
        "usesSharedRustCore": true,
        "secretsPassedThroughFlutterMethodChannel": false,
        "secretTransport": Self.mobileRelaySecretOverrideTransport,
        "secretsPersistedForHydration": false
      ],
      "pairwiseCryptoStatus": nativeReady
        ? "shared_rust_core_available_ios_keychain_memory_override"
        : "ios_secure_mesh_native_self_test_failed",
      "mlsCryptoStatus": "product_policy_bindings_implemented_product_messaging_disabled_until_physical_group_evidence",
      "mlsProductMessagingAvailable": false,
      "fileCryptoStatus": nativeReady
        ? "file_aead_shared_rust_core_available"
        : "file_aead_shared_rust_core_unavailable",
      "commandSecurityStatus": nativeReady
        ? "command_gate_shared_rust_core_available"
        : "command_gate_shared_rust_core_unavailable",
      "deviceTrustStatus": keychainReady
        ? "ios_keychain_available_memory_override_binding"
        : "ios_keychain_device_binding_unavailable",
      "cryptoCoreStatus": nativeReady
        ? "shared_rust_core_ready_ios_keychain_memory_override"
        : "shared_rust_core_blocked",
      "secretUnlockPolicy": [
        "requiredForPrivateKeyUse": true,
        "systemPolicy": "deviceOwnerAuthentication",
        "biometricDataHandledByApp": false,
        "appPasswordPromptUsed": false,
        "localizedErrorsIncluded": false,
        "implementationStatus": "ios_keychain_shared_rust_secret_store_handle_contract"
      ],
      "mobileRelaySecretStore": mobileRelaySecretStoreStatus(),
      "idleTimerGuard": [
        "available": true,
        "activeWhenForeground": UIApplication.shared.isIdleTimerDisabled
      ],
      "productionReady": false
    ]
  }

  func writeRuntimeStatus() -> [String: Any] {
    var payload = status()
    payload["runtimeStatusFile"] = [
      "relativePath": "Application Support/secure-mesh/ios-runtime-status.json",
      "writtenByAppProcess": true,
      "writtenAtEpochMillis": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    return writeJsonReport(
      payload,
      filename: "ios-runtime-status.json",
      okRelativePath: "Application Support/secure-mesh/ios-runtime-status.json"
    )
  }

  func writeLaunchRuntimeStatus() -> [String: Any] {
    let selfTestPassed = lico_secure_mesh_runtime_self_test() == 1
    let featureMask = lico_secure_mesh_runtime_feature_flags()
    var payload: [String: Any] = [
      "ok": selfTestPassed,
      "statusKind": "launch-runtime",
      "protocolVersion": "licolite.secure-mesh.v1",
      "endpointKind": "mobile",
      "platform": "ios",
      "bridge": [
        "methodChannel": Self.channelName,
        "statusMethod": true,
        "writeRuntimeStatusMethod": true,
        "nativeJsonMethod": true
      ],
      "nativeRuntime": [
        "provider": "lico-client-native",
        "ffiBoundary": "c-abi",
        "loaded": true,
        "selfTestPassed": selfTestPassed,
        "featureMask": Int(featureMask),
        "featureFlags": featureFlags(featureMask),
        "protocolHash": Int(lico_secure_mesh_runtime_protocol_hash()),
        "usesSharedRustCore": true,
        "secretsPassedThroughFlutterMethodChannel": false
      ],
      "credentialStoreEvaluated": false,
      "localAuthenticationEvaluated": false,
      "productionReady": false
    ]
    payload["runtimeStatusFile"] = [
      "relativePath": "Application Support/secure-mesh/ios-runtime-status.json",
      "writtenByAppProcess": true,
      "writtenAtEpochMillis": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    return writeJsonReport(
      payload,
      filename: "ios-runtime-status.json",
      okRelativePath: "Application Support/secure-mesh/ios-runtime-status.json"
    )
  }

  func nativeJson(_ arguments: Any?) -> [String: Any] {
    let requestText: String
    if let text = arguments as? String {
      requestText = text
    } else {
      do {
        let value = arguments ?? [:]
        guard JSONSerialization.isValidJSONObject(value) else {
          return errorResponse(
            code: "ios_secure_mesh_native_json_invalid_request",
            error: "nativeJson arguments must be a JSON object or JSON string."
          )
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        requestText = String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return errorResponse(
        code: "ios_secure_mesh_native_json_encode_failed",
        error: sanitizedBridgeError(error)
      )
    }
    }

    do {
      let action = nativeJsonAction(requestText)
      if action == "secure_mesh.ios.userPresenceProof" {
        return mobileRelayUserPresenceProof()
      }
      let callbackContext = SecureMeshIosSecretStoreCallbackContext(bridge: self)
      try redactPersistedMobileRelaySecrets(callbackContext: callbackContext)
      let effectiveRequestText = try requestTextWithMobileRelaySecretOverrides(
        requestText,
        action: action,
        callbackContext: callbackContext
      )
      let root = try appSupportRoot()
      let responsePointer = effectiveRequestText.withCString { requestCString in
        root.path.withCString { filesCString in
          Self.mobileRelaySecretStoreBackend.withCString { backendCString in
            var callbacks = LicoSecureMeshSecretStoreCallbacks()
            callbacks.ctx = Unmanaged.passUnretained(callbackContext).toOpaque()
            callbacks.backend = backendCString
            callbacks.set_secret = Self.iosSecretStoreSetCallback
            callbacks.get_secret = Self.iosSecretStoreGetCallback
            callbacks.delete_secret = Self.iosSecretStoreDeleteCallback
            callbacks.string_free = Self.iosSecretStoreStringFreeCallback
            return lico_secure_mesh_json_with_secret_store(
              requestCString,
              filesCString,
              &callbacks
            )
          }
        }
      }
      guard let responsePointer else {
        return errorResponse(
          code: "ios_secure_mesh_native_json_null_response",
          error: "Native Secure Mesh returned a null response."
        )
      }
      defer {
        lico_secure_mesh_string_free(responsePointer)
      }
      let responseText = String(cString: responsePointer)
      var response = parseJsonMap(responseText)
      try captureMobileRelaySecretsFromNativeResponse(&response, callbackContext: callbackContext)
      try redactPersistedMobileRelaySecrets(callbackContext: callbackContext)
      let callbackAuthReport = callbackContext.redactedReport()
      response["iosProductionCallbackAuth"] = callbackAuthReport
      response["secretStoreAuthorization"] = callbackContext.secretStoreAuthorizationReport()
      response["iosCallbackAuthContextCreated"] = callbackContext.authContextCreated
      response["iosCallbackReadsUseAuthenticationContext"] =
        callbackContext.callbackReadsUseAuthenticationContext
      response["iosCallbackReadsUseSharedLAContext"] =
        callbackContext.callbackReadsUseSharedLAContext
      response["iosSingleSystemAuthorizationContextVerified"] =
        callbackContext.singleSystemAuthorizationContextVerified
      response["iosPreDispatchSecretReadsUseAuthenticationContext"] =
        callbackContext.preDispatchSecretReadsUseAuthenticationContext
      response["iosCallbackAuthContextAttachedToAllReads"] =
        callbackContext.authContextAttachedToAllReads
      response["iosCallbackAuthContextAttachedToAllOperations"] =
        callbackContext.authContextAttachedToAllOperations
      response["iosSystemAuthorizationAttemptCount"] =
        callbackContext.systemAuthorizationAttemptCount
      response["iosSystemAuthorizationCompleted"] =
        callbackContext.systemAuthorizationCompleted
      response["iosAuthorizationBatchPromptBudgetReady"] =
        callbackContext.authorizationBatchPromptBudgetReady
      response["iosAuthorizationBatchWithinBudget"] =
        callbackContext.authorizationBatchWithinBudget
      response["appPasswordPromptUsed"] = false
      response["appCredentialPromptUsed"] = false
      response["keyMaterialExported"] = false
      return response
    } catch {
      return errorResponse(
        code: "ios_secure_mesh_native_json_failed",
        error: sanitizedBridgeError(error)
      )
    }
  }

  func writeJsonReport(
    _ payload: [String: Any],
    filename: String,
    okRelativePath: String
  ) -> [String: Any] {
    do {
      let directory = try secureMeshDirectory()
      prunePersistentDiagnostics(in: directory)
      let file = directory.appendingPathComponent(filename, isDirectory: false)
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: file, options: .atomic)
      return [
        "ok": true,
        "relativePath": okRelativePath,
        "writtenByAppProcess": true
      ]
    } catch {
      return [
        "ok": false,
        "relativePath": okRelativePath,
        "error": sanitizedBridgeError(error),
        "localizedErrorsIncluded": false
      ]
    }
  }

  func prunePersistentDiagnostics() {
    guard let directory = try? secureMeshDirectory() else {
      return
    }
    prunePersistentDiagnostics(in: directory)
  }

  func prunePersistentDiagnostics(in directory: URL) {
    let maxAge: TimeInterval = 7 * 24 * 60 * 60
    let maxFiles = 32
    let now = Date()
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }
    let diagnostics = files.filter { url in
      url.pathExtension == "json"
    }.compactMap { url -> (url: URL, modified: Date) in
      let values = try? url.resourceValues(forKeys: keys)
      guard values?.isRegularFile == true else {
        return (url, Date.distantPast)
      }
      return (url, values?.contentModificationDate ?? Date.distantPast)
    }.sorted { left, right in
      left.modified > right.modified
    }
    for item in diagnostics where now.timeIntervalSince(item.modified) > maxAge {
      try? fileManager.removeItem(at: item.url)
    }
    for item in diagnostics.dropFirst(maxFiles) {
      try? fileManager.removeItem(at: item.url)
    }
  }

  func appSupportRoot() throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = base.appendingPathComponent("LicoArc", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func secureMeshDirectory() throws -> URL {
    let directory = try appSupportRoot().appendingPathComponent("secure-mesh", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func mobileRelayConfigFile() throws -> URL {
    try appSupportRoot()
      .appendingPathComponent("portable-data", isDirectory: true)
      .appendingPathComponent("lico-client", isDirectory: true)
      .appendingPathComponent("mobile-relay", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  func readMobileRelayConfig() throws -> [String: Any]? {
    let file = try mobileRelayConfigFile()
    guard fileManager.fileExists(atPath: file.path) else {
      return nil
    }
    let data = try Data(contentsOf: file)
    let value = try JSONSerialization.jsonObject(with: data, options: [])
    return value as? [String: Any]
  }

  func writeMobileRelayConfig(_ config: [String: Any]) throws {
    let file = try mobileRelayConfigFile()
    let directory = file.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: config,
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: file, options: .atomic)
  }

  func nativeJsonAction(_ requestText: String) -> String {
    guard
      let data = requestText.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
      return ""
    }
    return (object["action"] as? String) ?? ""
  }

  func mobileRelayActionUsesSecretOverrides(_ action: String) -> Bool {
    switch action {
    case "mobile.relay.config.get":
      return false
    default:
      return action.hasPrefix("mobile.relay.")
    }
  }

  func featureFlags(_ mask: Int32) -> [String: Bool] {
    return [
      "protocolStatus": mask & (1 << 0) != 0,
      "envelopeValidation": mask & (1 << 1) != 0,
      "commandPolicy": mask & (1 << 2) != 0,
      "contentCrypto": mask & (1 << 3) != 0,
      "pairwiseRuntime": mask & (1 << 4) != 0,
      "mlsProductMessaging": false
    ]
  }

  func errorResponse(code: String, error _: String) -> [String: Any] {
    return [
      "ok": false,
      "protocolVersion": "licolite.secure-mesh.v1",
      "endpointKind": "mobile",
      "platform": "ios",
      "code": code,
      "error": "Secure Mesh request failed.",
      "errorDetailRedacted": true,
      "localizedErrorsIncluded": false,
      "productionReady": false
    ]
  }

  func sanitizedBridgeError(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSOSStatusErrorDomain {
      let status = OSStatus(nsError.code)
      return "\(securityStatusText(status)):\(securityDiagnosticCategory(status))"
    }
    return "domain:\(safeErrorDomain(nsError.domain));code:\(nsError.code)"
  }

  func safeErrorDomain(_ domain: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = domain.unicodeScalars.map { scalar -> String in
      allowed.contains(scalar) ? String(scalar) : "_"
    }
    let sanitized = scalars.joined()
    return sanitized.isEmpty ? "redacted" : sanitized
  }

  func securityStatusText(_ status: OSStatus) -> String {
    if status == errSecSuccess {
      return "ok"
    }
    return "osstatus_\(status)"
  }

  func securityDiagnosticCategory(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess:
      return "ready"
    case errSecItemNotFound:
      return "item_not_found"
    case errSecInteractionNotAllowed:
      return "interaction_not_allowed"
    case errSecAuthFailed:
      return "authentication_failed"
    case errSecUserCanceled:
      return "user_cancelled"
    case errSecMissingEntitlement:
      return "missing_keychain_entitlement"
    case errSecDecode, errSecParam:
      return "keychain_query_or_access_control_invalid"
    default:
      return "keychain_unavailable"
    }
  }

}

final class SecureMeshIosSecretStoreCallbackContext {
  static let authorizationBatchOperationBudget = 128
  static let allowableReuseDurationSeconds = 300

  let bridge: SecureMeshIosBridge
  let localAuthenticationContext: LAContext

  private(set) var preDispatchSecretReadCount = 0
  private(set) var preDispatchSecretReadWithAuthenticationContextCount = 0
  private(set) var preDispatchSecretWriteCount = 0
  private(set) var preDispatchSecretWriteWithAuthenticationContextCount = 0
  private(set) var preDispatchSecretDeleteCount = 0
  private(set) var preDispatchSecretDeleteWithAuthenticationContextCount = 0
  private(set) var callbackSecretReadCount = 0
  private(set) var callbackSecretReadWithAuthenticationContextCount = 0
  private(set) var callbackSecretWriteCount = 0
  private(set) var callbackSecretWriteWithAuthenticationContextCount = 0
  private(set) var callbackSecretDeleteCount = 0
  private(set) var callbackSecretDeleteWithAuthenticationContextCount = 0

  init(bridge: SecureMeshIosBridge) {
    self.bridge = bridge
    let context = LAContext()
    context.localizedReason = "Unlock Arc secure relay keys"
    context.touchIDAuthenticationAllowableReuseDuration =
      TimeInterval(Self.allowableReuseDurationSeconds)
    self.localAuthenticationContext = context
  }

  var authContextCreated: Bool {
    true
  }

  var callbackReadsUseAuthenticationContext: Bool {
    callbackSecretReadCount > 0 &&
      callbackSecretReadWithAuthenticationContextCount == callbackSecretReadCount
  }

  var callbackReadsUseSharedLAContext: Bool {
    callbackReadsUseAuthenticationContext
  }

  var callbackWritesUseAuthenticationContext: Bool {
    callbackSecretWriteWithAuthenticationContextCount == callbackSecretWriteCount
  }

  var callbackDeletesUseAuthenticationContext: Bool {
    callbackSecretDeleteWithAuthenticationContextCount == callbackSecretDeleteCount
  }

  var preDispatchSecretReadsUseAuthenticationContext: Bool {
    preDispatchSecretReadWithAuthenticationContextCount == preDispatchSecretReadCount
  }

  var preDispatchSecretWritesUseAuthenticationContext: Bool {
    preDispatchSecretWriteWithAuthenticationContextCount == preDispatchSecretWriteCount
  }

  var preDispatchSecretDeletesUseAuthenticationContext: Bool {
    preDispatchSecretDeleteWithAuthenticationContextCount == preDispatchSecretDeleteCount
  }

  var authContextAttachedToAllReads: Bool {
    let totalReadCount = preDispatchSecretReadCount + callbackSecretReadCount
    let attachedReadCount =
      preDispatchSecretReadWithAuthenticationContextCount +
      callbackSecretReadWithAuthenticationContextCount
    return totalReadCount > 0 && attachedReadCount == totalReadCount
  }

  var authContextAttachedToAllOperations: Bool {
    let totalOperationCount = authorizationBatchConsumedOperationCount
    let attachedOperationCount =
      preDispatchSecretReadWithAuthenticationContextCount +
      preDispatchSecretWriteWithAuthenticationContextCount +
      preDispatchSecretDeleteWithAuthenticationContextCount +
      callbackSecretReadWithAuthenticationContextCount +
      callbackSecretWriteWithAuthenticationContextCount +
      callbackSecretDeleteWithAuthenticationContextCount
    return totalOperationCount > 0 && attachedOperationCount == totalOperationCount
  }

  var authorizationBatchOperationCount: Int {
    Self.authorizationBatchOperationBudget
  }

  var authorizationBatchConsumedOperationCount: Int {
    preDispatchSecretReadCount +
      preDispatchSecretWriteCount +
      preDispatchSecretDeleteCount +
      callbackSecretReadCount +
      callbackSecretWriteCount +
      callbackSecretDeleteCount
  }

  var authorizationBatchRemainingOperationCount: Int {
    max(0, authorizationBatchOperationCount - authorizationBatchConsumedOperationCount)
  }

  var authorizationBatchWithinBudget: Bool {
    authorizationBatchConsumedOperationCount > 0 &&
      authorizationBatchConsumedOperationCount <= authorizationBatchOperationCount
  }

  var systemAuthorizationAttemptCount: Int {
    authorizationBatchConsumedOperationCount > 0 ? 1 : 0
  }

  var systemAuthorizationCompleted: Bool {
    callbackSecretReadCount > 0 &&
      authContextAttachedToAllOperations &&
      authorizationBatchWithinBudget
  }

  var authorizationBatchPromptBudgetReady: Bool {
    systemAuthorizationAttemptCount == 1 &&
      systemAuthorizationCompleted &&
      authorizationBatchWithinBudget
  }

  var singleSystemAuthorizationContextVerified: Bool {
    authContextCreated &&
      authContextAttachedToAllOperations &&
      callbackReadsUseSharedLAContext &&
      callbackWritesUseAuthenticationContext &&
      callbackDeletesUseAuthenticationContext &&
      preDispatchSecretReadsUseAuthenticationContext &&
      preDispatchSecretWritesUseAuthenticationContext &&
      preDispatchSecretDeletesUseAuthenticationContext
  }

  var productionCallbackAuthReady: Bool {
    singleSystemAuthorizationContextVerified &&
      authorizationBatchPromptBudgetReady
  }

  func recordPreDispatchSecretRead(authenticationContextAttached: Bool) {
    preDispatchSecretReadCount += 1
    if authenticationContextAttached {
      preDispatchSecretReadWithAuthenticationContextCount += 1
    }
  }

  func recordPreDispatchSecretWrite(authenticationContextAttached: Bool) {
    preDispatchSecretWriteCount += 1
    if authenticationContextAttached {
      preDispatchSecretWriteWithAuthenticationContextCount += 1
    }
  }

  func recordPreDispatchSecretDelete(authenticationContextAttached: Bool) {
    preDispatchSecretDeleteCount += 1
    if authenticationContextAttached {
      preDispatchSecretDeleteWithAuthenticationContextCount += 1
    }
  }

  func recordCallbackSecretRead(authenticationContextAttached: Bool) {
    callbackSecretReadCount += 1
    if authenticationContextAttached {
      callbackSecretReadWithAuthenticationContextCount += 1
    }
  }

  func recordCallbackSecretWrite(authenticationContextAttached: Bool) {
    callbackSecretWriteCount += 1
    if authenticationContextAttached {
      callbackSecretWriteWithAuthenticationContextCount += 1
    }
  }

  func recordCallbackSecretDelete(authenticationContextAttached: Bool) {
    callbackSecretDeleteCount += 1
    if authenticationContextAttached {
      callbackSecretDeleteWithAuthenticationContextCount += 1
    }
  }

  func secretStoreAuthorizationReport() -> [String: Any] {
    return [
      "backend": SecureMeshIosBridge.mobileRelaySecretStoreBackend,
      "operationCount": authorizationBatchOperationCount,
      "allowInteraction": true,
      "sharedSystemAuthorizationContextRequired": true,
      "sharedSystemAuthorizationContextAvailable": authContextCreated,
      "singleSystemAuthorizationContextVerified": singleSystemAuthorizationContextVerified,
      "systemAuthorizationAttemptCount": systemAuthorizationAttemptCount,
      "systemAuthorizationCompleted": systemAuthorizationCompleted,
      "authorizationBatchPromptBudgetReady": authorizationBatchPromptBudgetReady,
      "consumedOperationCount": authorizationBatchConsumedOperationCount,
      "remainingOperationCount": authorizationBatchRemainingOperationCount,
      "authorizationBatchWithinBudget": authorizationBatchWithinBudget,
      "appCredentialPromptUsed": false,
      "appPasswordPromptUsed": false,
      "keyMaterialExported": false
    ]
  }

  func redactedReport() -> [String: Any] {
    return [
      "iosProductionCallbackAuthReady": productionCallbackAuthReady,
      "iosCallbackAuthContextCreated": authContextCreated,
      "iosCallbackReadsUseAuthenticationContext": callbackReadsUseAuthenticationContext,
      "iosCallbackReadsUseSharedLAContext": callbackReadsUseSharedLAContext,
      "iosSingleSystemAuthorizationContextVerified": singleSystemAuthorizationContextVerified,
      "iosPreDispatchSecretReadsUseAuthenticationContext":
        preDispatchSecretReadsUseAuthenticationContext,
      "iosCallbackAuthContextAttachedToAllReads": authContextAttachedToAllReads,
      "iosCallbackAuthContextAttachedToAllOperations": authContextAttachedToAllOperations,
      "systemAuthorizationAttemptCount": systemAuthorizationAttemptCount,
      "systemAuthorizationCompleted": systemAuthorizationCompleted,
      "authorizationBatchPromptBudgetReady": authorizationBatchPromptBudgetReady,
      "authorizationBatchOperationCount": authorizationBatchOperationCount,
      "authorizationBatchConsumedOperationCount": authorizationBatchConsumedOperationCount,
      "authorizationBatchRemainingOperationCount": authorizationBatchRemainingOperationCount,
      "authorizationBatchWithinBudget": authorizationBatchWithinBudget,
      "sharedSystemAuthorizationContextRequired": true,
      "sharedSystemAuthorizationContextAvailable": authContextCreated,
      "allowableReuseDurationSeconds": Self.allowableReuseDurationSeconds,
      "authenticationReuseWindowConfigured": true,
      "preDispatchSecretReadCount": preDispatchSecretReadCount,
      "preDispatchSecretReadWithAuthenticationContextCount":
        preDispatchSecretReadWithAuthenticationContextCount,
      "preDispatchSecretWriteCount": preDispatchSecretWriteCount,
      "preDispatchSecretWriteWithAuthenticationContextCount":
        preDispatchSecretWriteWithAuthenticationContextCount,
      "preDispatchSecretDeleteCount": preDispatchSecretDeleteCount,
      "preDispatchSecretDeleteWithAuthenticationContextCount":
        preDispatchSecretDeleteWithAuthenticationContextCount,
      "callbackSecretReadCount": callbackSecretReadCount,
      "callbackSecretReadWithAuthenticationContextCount":
        callbackSecretReadWithAuthenticationContextCount,
      "callbackSecretWriteCount": callbackSecretWriteCount,
      "callbackSecretWriteWithAuthenticationContextCount":
        callbackSecretWriteWithAuthenticationContextCount,
      "callbackSecretDeleteCount": callbackSecretDeleteCount,
      "callbackSecretDeleteWithAuthenticationContextCount":
        callbackSecretDeleteWithAuthenticationContextCount,
      "credentialEntrySurface": "ios_system_local_auth_prompt",
      "systemPromptSurface": "ios_system_local_auth_prompt",
      "appPasswordPromptUsedPresent": true,
      "appPasswordPromptUsed": false,
      "appCredentialPromptUsedPresent": true,
      "appCredentialPromptUsed": false,
      "biometricDataHandledByApp": false,
      "keyMaterialExportedPresent": true,
      "keyMaterialExported": false,
      "rawSecretMaterialIncludedPresent": true,
      "rawSecretMaterialIncluded": false,
      "localizedErrorsIncludedPresent": true,
      "localizedErrorsIncluded": false
    ]
  }
}
