import Darwin
import CryptoKit
import Foundation
import LocalAuthentication
import Security

extension SecureMeshIosBridge {
  func keychainStatus() -> [String: Any] {
    let service = "app.licoarc.secure-mesh.runtime"
    let account = "runtime-self-test"
    let data = Data("keychain-self-test".utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

    var copyQuery = query
    copyQuery[kSecReturnData as String] = true
    copyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var copied: CFTypeRef?
    let copyStatus = SecItemCopyMatching(copyQuery as CFDictionary, &copied)
    SecItemDelete(query as CFDictionary)
    let userPresenceAccessControl = userPresenceAccessControlCreationStatus()

    return [
      "provider": "iOS Keychain",
      "available": addStatus == errSecSuccess && copyStatus == errSecSuccess,
      "accessibility": "AfterFirstUnlockThisDeviceOnly",
      "thisDeviceOnlyWhenUnlockedAccessControlAvailable":
        userPresenceAccessControl["created"] as? Bool == true,
      "userPresenceAccessControl": userPresenceAccessControl,
      "secureEnclaveRequired": false,
      "mobileRelayPrivateKeyBinding": "ios_keychain_shared_rust_secret_store_handle_contract",
      "addStatus": securityStatusText(addStatus),
      "addDiagnosticCategory": securityDiagnosticCategory(addStatus),
      "copyStatus": securityStatusText(copyStatus),
      "copyDiagnosticCategory": securityDiagnosticCategory(copyStatus),
      "localizedErrorsIncluded": false
    ]
  }

  func mobileRelaySecretStoreStatus() -> [String: Any] {
    let config = (try? readMobileRelayConfig()) ?? nil
    let hasPlaintext = mobileRelayConfigHasPlaintextSecrets(config)
    let userPresenceAccessControl = userPresenceAccessControlCreationStatus()
    return [
      "provider": "iOS Keychain",
      "service": mobileRelaySecretService,
      "accessibility": "WhenUnlockedThisDeviceOnly",
      "accessControl": "userPresence",
      "biometricDataHandledByApp": false,
      "appPasswordPromptUsed": false,
      "appCredentialPromptUsed": false,
      "userAuthenticationRequired": true,
      "credentialEntrySurface": "ios_system_local_auth_prompt",
      "sharedSystemAuthorizationContextRequired": true,
      "sharedSystemAuthorizationContextAvailable": true,
      "allowableReuseDurationSeconds":
        SecureMeshIosSecretStoreCallbackContext.allowableReuseDurationSeconds,
      "authenticationReuseWindowConfigured": true,
      "keyMaterialExported": false,
      "localizedErrorsIncluded": false,
      "keychainUserPresencePolicyReady":
        userPresenceAccessControl["created"] as? Bool == true,
      "userPresenceAccessControl": userPresenceAccessControl,
      "secretStoreContract": Self.mobileRelaySecretStoreContract,
      "secretStoreBackend": Self.mobileRelaySecretStoreBackend,
      "secretStoreAccountPrefix": Self.mobileRelaySecretStoreAccountPrefix,
      "secretStoreNamespace": Self.mobileRelaySecretStoreNamespace,
      "secretStoreHandlePattern": "accountPrefix:namespace:key",
      "mobileRelayE2eeSecretStore": true,
      "rawJsonSecretOverridesUsed": false,
      "sharedRustSecretStoreHandleContract": true,
      "secretClasses": [
        "endpointPrivateKey",
        "signingKey",
        "signedPrekeyPrivateKey",
        "oneTimePrekeyPrivateKey",
        "pairingSecret",
        "pairwiseSessionSnapshot"
      ],
      "portableConfigRedacted": !hasPlaintext,
      "implementationStatus": "ios_keychain_shared_rust_secret_store_handle_contract"
    ]
  }


  func requestTextWithMobileRelaySecretOverrides(
    _ requestText: String,
    action: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws -> String {
    guard
      let data = requestText.data(using: .utf8),
      var object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
      return requestText
    }
    var params = object["params"] as? [String: Any] ?? [:]
    let removedCallerSuppliedOverrides = params.removeValue(forKey: "secretOverrides") != nil ||
      params.removeValue(forKey: "secretOverrideTransport") != nil
    guard mobileRelayActionUsesSecretOverrides(action) else {
      if removedCallerSuppliedOverrides {
        object["params"] = params
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: encoded, encoding: .utf8) ?? requestText
      }
      return requestText
    }
    let overrides = try mobileRelaySecretOverrides(callbackContext: callbackContext)
    guard !overrides.isEmpty else {
      if removedCallerSuppliedOverrides {
        object["params"] = params
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: encoded, encoding: .utf8) ?? requestText
      }
      return requestText
    }
    params["secretOverrides"] = overrides
    params["secretOverrideTransport"] = Self.mobileRelaySecretOverrideTransport
    params["secretOverrideBackend"] = Self.mobileRelaySecretStoreBackend
    object["params"] = params
    let encoded = try JSONSerialization.data(withJSONObject: object, options: [])
    return String(data: encoded, encoding: .utf8) ?? requestText
  }

  func captureMobileRelaySecretsFromNativeResponse(
    _ response: inout [String: Any],
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    try persistResponseSecret(
      &response,
      key: "mobileToken",
      account: "mobileToken",
      callbackContext: callbackContext
    )
    try persistResponseSecret(
      &response,
      key: "pcToken",
      account: "pcToken",
      callbackContext: callbackContext
    )
    try captureTopLevelMobileRelayE2eeSecrets(&response, callbackContext: callbackContext)

    if var e2ee = response["mobileRelayE2ee"] as? [String: Any] {
      try captureMobileRelayE2eeSecrets(&e2ee, callbackContext: callbackContext)
      response["mobileRelayE2ee"] = e2ee
    }

    if var invite = response["mobileRelayPairingInvite"] as? [String: Any] {
      try capturePairingInviteSecret(&invite, callbackContext: callbackContext)
      response["mobileRelayPairingInvite"] = invite
    }
    if var invite = response["pairingInvite"] as? [String: Any] {
      try capturePairingInviteSecret(&invite, callbackContext: callbackContext)
      response["pairingInvite"] = invite
    }
    if var invite = response["invite"] as? [String: Any] {
      try capturePairingInviteSecret(&invite, callbackContext: callbackContext)
      response["invite"] = invite
    }

    if var config = response["config"] as? [String: Any] {
      try captureMobileRelayConfigSecrets(&config, callbackContext: callbackContext)
      response["config"] = config
    }
  }

  func captureTopLevelMobileRelayE2eeSecrets(
    _ response: inout [String: Any],
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    var captured = false
    captured = try persistResponseSecret(
      &response,
      key: "privateKeyBase64url",
      account: "privateKeyBase64url",
      callbackContext: callbackContext
    ) || captured
    captured = try persistResponseSecret(
      &response,
      key: "signingKeyBase64url",
      account: "signingKeyBase64url",
      callbackContext: callbackContext
    ) || captured
    captured = try persistResponseSecret(
      &response,
      key: "signedPrekeyPrivateKeyBase64url",
      account: "signedPrekeyPrivateKeyBase64url",
      callbackContext: callbackContext
    ) || captured
    captured = try persistResponseSecret(
      &response,
      key: "oneTimePrekeyPrivateKeyBase64url",
      account: "oneTimePrekeyPrivateKeyBase64url",
      callbackContext: callbackContext
    ) || captured
    captured = try persistResponseSecret(
      &response,
      key: "pairingSecretBase64url",
      account: "pairingSecretBase64url",
      callbackContext: callbackContext
    ) || captured
    if captured {
      response["mobileRelayE2eeSecretStorageStatus"] =
        "ios_keychain_shared_rust_secret_store_handle_contract"
    }
  }

  func captureMobileRelayConfigSecrets(
    _ config: inout [String: Any],
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    try persistResponseSecret(&config, key: "pcToken", account: "pcToken", callbackContext: callbackContext)
    try persistResponseSecret(&config, key: "mobileToken", account: "mobileToken", callbackContext: callbackContext)
    if var e2ee = config["mobileRelayE2ee"] as? [String: Any] {
      try captureMobileRelayE2eeSecrets(&e2ee, callbackContext: callbackContext)
      config["mobileRelayE2ee"] = e2ee
    }
    if var invite = config["mobileRelayPairingInvite"] as? [String: Any] {
      try capturePairingInviteSecret(&invite, callbackContext: callbackContext)
      config["mobileRelayPairingInvite"] = invite
    }
    if var devices = config["pairedDevices"] as? [[String: Any]] {
      for index in devices.indices {
        let account = pairedDeviceTokenAccount(devices[index])
        if let secret = devices[index]["mobileToken"] as? String,
           secretTextPresent(secret) {
          try writeMobileRelaySecret(secret, account: account, callbackContext: callbackContext)
          devices[index]["mobileToken"] = ""
          devices[index]["credentialPresent"] = true
        }
      }
      config["pairedDevices"] = devices
    }
  }

  func captureMobileRelayE2eeSecrets(
    _ e2ee: inout [String: Any],
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    var changed = false
    try persistNestedSecret(
      &e2ee,
      key: "privateKeyBase64url",
      account: "privateKeyBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    try persistNestedSecret(
      &e2ee,
      key: "signingKeyBase64url",
      account: "signingKeyBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    try persistNestedSecret(
      &e2ee,
      key: "signedPrekeyPrivateKeyBase64url",
      account: "signedPrekeyPrivateKeyBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    try persistNestedSecret(
      &e2ee,
      key: "oneTimePrekeyPrivateKeyBase64url",
      account: "oneTimePrekeyPrivateKeyBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    try persistNestedSecret(
      &e2ee,
      key: "pairingSecretBase64url",
      account: "pairingSecretBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    if changed {
      e2ee["privateKeyMaterial"] = "redacted"
      e2ee["signingKeyMaterial"] = "redacted"
      e2ee["signedPrekeyPrivateKeyMaterial"] = "redacted"
      e2ee["oneTimePrekeyPrivateKeyMaterial"] = "redacted"
      e2ee["pairingSecretMaterial"] = "redacted"
      e2ee["secretStorageStatus"] = "ios_keychain_shared_rust_secret_store_handle_contract"
    }
  }

  func capturePairingInviteSecret(
    _ invite: inout [String: Any],
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    var changed = false
    try persistNestedSecret(
      &invite,
      key: "e2eePairingSecret",
      account: "pairingSecretBase64url",
      changed: &changed,
      callbackContext: callbackContext
    )
    if changed {
      invite["e2eePairingSecretMaterial"] = "redacted"
    }
  }

  func mobileRelaySecretOverrides(
    callbackContext _: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws -> [String: Any] {
    return [
      "mobileRelayE2eeSecretStore": [
        "contract": Self.mobileRelaySecretStoreContract,
        "backend": Self.mobileRelaySecretStoreBackend,
        "namespace": Self.mobileRelaySecretStoreNamespace,
        "accountPrefix": Self.mobileRelaySecretStoreAccountPrefix,
        "rawJsonSecretOverridesUsed": false
      ]
    ]
  }

  func redactPersistedMobileRelaySecrets(
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    guard var config = try readMobileRelayConfig() else {
      return
    }
    var changed = false
    try persistTopLevelSecret(
      &config,
      key: "pcToken",
      account: "pcToken",
      changed: &changed,
      callbackContext: callbackContext
    )
    try persistTopLevelSecret(
      &config,
      key: "mobileToken",
      account: "mobileToken",
      changed: &changed,
      callbackContext: callbackContext
    )
    if var e2ee = config["mobileRelayE2ee"] as? [String: Any] {
      try persistNestedSecret(
        &e2ee,
        key: "privateKeyBase64url",
        account: "privateKeyBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      try persistNestedSecret(
        &e2ee,
        key: "signingKeyBase64url",
        account: "signingKeyBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      try persistNestedSecret(
        &e2ee,
        key: "signedPrekeyPrivateKeyBase64url",
        account: "signedPrekeyPrivateKeyBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      try persistNestedSecret(
        &e2ee,
        key: "oneTimePrekeyPrivateKeyBase64url",
        account: "oneTimePrekeyPrivateKeyBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      try persistNestedSecret(
        &e2ee,
        key: "pairingSecretBase64url",
        account: "pairingSecretBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      e2ee["privateKeyMaterial"] = "redacted"
      e2ee["signingKeyMaterial"] = "redacted"
      e2ee["signedPrekeyPrivateKeyMaterial"] = "redacted"
      e2ee["oneTimePrekeyPrivateKeyMaterial"] = "redacted"
      e2ee["pairingSecretMaterial"] = "redacted"
      e2ee["secretStorageStatus"] = "ios_keychain_shared_rust_secret_store_handle_contract"
      config["mobileRelayE2ee"] = e2ee
      changed = true
    }
    if var invite = config["mobileRelayPairingInvite"] as? [String: Any] {
      try persistNestedSecret(
        &invite,
        key: "e2eePairingSecret",
        account: "pairingSecretBase64url",
        changed: &changed,
        callbackContext: callbackContext
      )
      invite["e2eePairingSecretMaterial"] = "redacted"
      config["mobileRelayPairingInvite"] = invite
      changed = true
    }
    if var devices = config["pairedDevices"] as? [[String: Any]] {
      for index in devices.indices {
        let account = pairedDeviceTokenAccount(devices[index])
        if let secret = devices[index]["mobileToken"] as? String,
           secretTextPresent(secret) {
          try writeMobileRelaySecret(secret, account: account, callbackContext: callbackContext)
          devices[index]["mobileToken"] = ""
          devices[index]["credentialPresent"] = true
          changed = true
        }
      }
      config["pairedDevices"] = devices
    }
    config["secretStorageStatus"] = [
      "tokenMaterial": "redacted",
      "mobileRelayPrivateKeyMaterial": "redacted",
      "persistentBackend": "ios_keychain_shared_rust_secret_store_handle_contract",
      "secretStoreContract": Self.mobileRelaySecretStoreContract,
      "secretStoreNamespace": Self.mobileRelaySecretStoreNamespace,
      "platformSecretStoreRequired": true
    ]
    changed = true
    if changed {
      try writeMobileRelayConfig(config)
    }
  }

  func persistTopLevelSecret(
    _ config: inout [String: Any],
    key: String,
    account: String,
    changed: inout Bool,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    guard let secret = config[key] as? String, secretTextPresent(secret) else {
      return
    }
    try writeMobileRelaySecret(secret, account: account, callbackContext: callbackContext)
    config[key] = ""
    config["\(key)Present"] = true
    changed = true
  }

  @discardableResult
  func persistResponseSecret(
    _ object: inout [String: Any],
    key: String,
    account: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws -> Bool {
    guard let secret = object[key] as? String, secretTextPresent(secret) else {
      return false
    }
    try writeMobileRelaySecret(secret, account: account, callbackContext: callbackContext)
    object[key] = ""
    object["\(key)Present"] = true
    return true
  }

  func persistNestedSecret(
    _ object: inout [String: Any],
    key: String,
    account: String,
    changed: inout Bool,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    guard let secret = object[key] as? String, secretTextPresent(secret) else {
      return
    }
    try writeMobileRelaySecret(secret, account: account, callbackContext: callbackContext)
    object.removeValue(forKey: key)
    changed = true
  }

  func mobileRelayConfigHasPlaintextSecrets(_ config: [String: Any]?) -> Bool {
    guard let config else {
      return false
    }
    if secretTextPresent(config["pcToken"]) || secretTextPresent(config["mobileToken"]) {
      return true
    }
    if let e2ee = config["mobileRelayE2ee"] as? [String: Any],
       secretTextPresent(e2ee["privateKeyBase64url"]) ||
       secretTextPresent(e2ee["signingKeyBase64url"]) ||
       secretTextPresent(e2ee["signedPrekeyPrivateKeyBase64url"]) ||
       secretTextPresent(e2ee["oneTimePrekeyPrivateKeyBase64url"]) ||
       secretTextPresent(e2ee["pairingSecretBase64url"]) {
      return true
    }
    if let devices = config["pairedDevices"] as? [[String: Any]] {
      return devices.contains { secretTextPresent($0["mobileToken"]) }
    }
    return false
  }

  func pairedDeviceTokenAccount(_ device: [String: Any]) -> String {
    let pairingId = (device["pairingId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = (device["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = [pairingId, id].compactMap { value in
      value?.isEmpty == false ? value : nil
    }.first ?? "unknown"
    return "pairedDevices.\(sha256Hex(suffix)).mobileToken"
  }

  func secretTextPresent(_ value: Any?) -> Bool {
    guard let text = value as? String else {
      return false
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "redacted" && trimmed != "***" && trimmed != "********"
  }

  func writeMobileRelaySecret(
    _ secret: String,
    account: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws {
    try writeMobileRelaySecret(
      secret,
      storedAccount: try mobileRelaySecretStoreAccount(account),
      callbackContext: callbackContext
    )
  }

  func writeMobileRelaySecret(
    _ secret: String,
    storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackWrite: Bool = false
  ) throws {
    guard let data = secret.data(using: .utf8) else {
      throw NSError(domain: "SecureMeshIosBridge", code: 1)
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: mobileRelaySecretService,
      kSecAttrAccount as String: storedAccount
    ]
    var deleteQuery = query
    if let callbackContext {
      deleteQuery[kSecUseAuthenticationContext as String] =
        callbackContext.localAuthenticationContext
      if callbackWrite {
        callbackContext.recordCallbackSecretDelete(authenticationContextAttached: true)
      } else {
        callbackContext.recordPreDispatchSecretDelete(authenticationContextAttached: true)
      }
    }
    SecItemDelete(deleteQuery as CFDictionary)
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .userPresence,
        &error
      )
    else {
      throw error?.takeRetainedValue() as Error? ?? NSError(domain: NSOSStatusErrorDomain, code: Int(errSecParam))
    }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessControl as String] = access
    if let callbackContext {
      addQuery[kSecUseAuthenticationContext as String] =
        callbackContext.localAuthenticationContext
      if callbackWrite {
        callbackContext.recordCallbackSecretWrite(authenticationContextAttached: true)
      } else {
        callbackContext.recordPreDispatchSecretWrite(authenticationContextAttached: true)
      }
    }
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  func readMobileRelaySecret(
    account: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil
  ) throws -> String? {
    let handleAccount = try mobileRelaySecretStoreAccount(account)
    if let secret = try readMobileRelaySecretFromStoredAccount(
      handleAccount,
      callbackContext: callbackContext,
      callbackRead: false
    ) {
      return secret
    }
    return nil
  }

  func readMobileRelaySecretFromStoredAccount(
    _ storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackRead: Bool = false
  ) throws -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: mobileRelaySecretService,
      kSecAttrAccount as String: storedAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseOperationPrompt as String: "Unlock Arc secure relay keys"
    ]
    if let callbackContext {
      query[kSecUseAuthenticationContext as String] =
        callbackContext.localAuthenticationContext
      if callbackRead {
        callbackContext.recordCallbackSecretRead(authenticationContextAttached: true)
      } else {
        callbackContext.recordPreDispatchSecretRead(authenticationContextAttached: true)
      }
    }
    var copied: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &copied)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    guard let data = copied as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func deleteMobileRelaySecretAccount(
    _ storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackDelete: Bool = false
  ) {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: mobileRelaySecretService,
      kSecAttrAccount as String: storedAccount
    ]
    if let callbackContext {
      query[kSecUseAuthenticationContext as String] =
        callbackContext.localAuthenticationContext
      if callbackDelete {
        callbackContext.recordCallbackSecretDelete(authenticationContextAttached: true)
      } else {
        callbackContext.recordPreDispatchSecretDelete(authenticationContextAttached: true)
      }
    }
    SecItemDelete(query as CFDictionary)
  }

  func mobileRelaySecretStoreAccount(_ secretStoreKey: String) throws -> String {
    let key = secretStoreKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !key.contains(":") else {
      throw NSError(domain: "SecureMeshIosBridge", code: 2)
    }
    return "\(Self.mobileRelaySecretStoreAccountPrefix):\(Self.mobileRelaySecretStoreNamespace):\(key)"
  }

  func mobileRelaySecretStoreCallbackAccount(namespace: String, key: String) throws -> String {
    let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalizedNamespace.isEmpty,
      !normalizedNamespace.contains("/"),
      !normalizedNamespace.contains("\u{0000}")
    else {
      throw NSError(domain: "SecureMeshIosBridge", code: 3)
    }
    guard
      !normalizedKey.isEmpty,
      !normalizedKey.contains(":"),
      !normalizedKey.contains("/"),
      !normalizedKey.contains("\u{0000}")
    else {
      throw NSError(domain: "SecureMeshIosBridge", code: 4)
    }
    if normalizedNamespace.hasPrefix("\(Self.mobileRelaySecretStoreAccountPrefix):") {
      return "\(normalizedNamespace):\(normalizedKey)"
    }
    return "\(Self.mobileRelaySecretStoreAccountPrefix):\(normalizedNamespace):\(normalizedKey)"
  }

  static let iosSecretStoreSetCallback:
    @convention(c) (
      UnsafeMutableRawPointer?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?
    ) -> Bool = { context, namespace, key, secret in
      do {
        let callbackContext = try callbackContextFromSecretStoreContext(context)
        let bridge = callbackContext.bridge
        let storedAccount = try bridge.mobileRelaySecretStoreCallbackAccount(
          namespace: try callbackString(namespace, name: "namespace"),
          key: try callbackString(key, name: "key")
        )
        try bridge.writeMobileRelaySecret(
          try callbackString(secret, name: "secret"),
          storedAccount: storedAccount,
          callbackContext: callbackContext,
          callbackWrite: true
        )
        return true
      } catch {
        return false
      }
    }

  static let iosSecretStoreGetCallback:
    @convention(c) (
      UnsafeMutableRawPointer?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? = { context, namespace, key in
      do {
        let callbackContext = try callbackContextFromSecretStoreContext(context)
        let bridge = callbackContext.bridge
        let storedAccount = try bridge.mobileRelaySecretStoreCallbackAccount(
          namespace: try callbackString(namespace, name: "namespace"),
          key: try callbackString(key, name: "key")
        )
        guard let secret = try bridge.readMobileRelaySecretFromStoredAccount(
          storedAccount,
          callbackContext: callbackContext,
          callbackRead: true
        ) else {
          return nil
        }
        return strdup(secret)
      } catch {
        return nil
      }
    }

  static let iosSecretStoreDeleteCallback:
    @convention(c) (
      UnsafeMutableRawPointer?,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?
    ) -> Bool = { context, namespace, key in
      do {
        let callbackContext = try callbackContextFromSecretStoreContext(context)
        let bridge = callbackContext.bridge
        let storedAccount = try bridge.mobileRelaySecretStoreCallbackAccount(
          namespace: try callbackString(namespace, name: "namespace"),
          key: try callbackString(key, name: "key")
        )
        bridge.deleteMobileRelaySecretAccount(
          storedAccount,
          callbackContext: callbackContext,
          callbackDelete: true
        )
        return true
      } catch {
        return false
      }
    }

  static let iosSecretStoreStringFreeCallback:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, value in
      if let value {
        free(value)
      }
    }

  static func callbackContextFromSecretStoreContext(
    _ context: UnsafeMutableRawPointer?
  ) throws -> SecureMeshIosSecretStoreCallbackContext {
    guard let context else {
      throw NSError(domain: "SecureMeshIosBridge", code: 5)
    }
    return Unmanaged<SecureMeshIosSecretStoreCallbackContext>
      .fromOpaque(context)
      .takeUnretainedValue()
  }

  static func callbackString(
    _ value: UnsafePointer<CChar>?,
    name: String
  ) throws -> String {
    guard let value else {
      throw NSError(domain: "SecureMeshIosBridge.\(name)", code: 6)
    }
    return String(cString: value)
  }

  func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func parseJsonMap(_ text: String) -> [String: Any] {
    guard let data = text.data(using: .utf8) else {
      return errorResponse(
        code: "ios_secure_mesh_native_json_utf8_failed",
        error: "Native response was not valid UTF-8."
      )
    }
    do {
      let value = try JSONSerialization.jsonObject(with: data, options: [])
      if let map = value as? [String: Any] {
        return map
      }
      return errorResponse(
        code: "ios_secure_mesh_native_json_invalid_response",
        error: "Native response was not a JSON object."
      )
    } catch {
      return errorResponse(
        code: "ios_secure_mesh_native_json_parse_failed",
        error: sanitizedBridgeError(error)
      )
    }
  }
}
