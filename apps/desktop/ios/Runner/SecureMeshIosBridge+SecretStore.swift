import Darwin
import Foundation
import Security

extension SecureMeshIosBridge {
  func keychainStatus() -> [String: Any] {
    let service = "app.licoarc.secure-mesh.runtime"
    let account = "runtime-self-test-\(UUID().uuidString)"
    let data = Data("keychain-self-test".utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
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
      "nativeFfiCarriesInProcessSecretMaterial": true,
      "secretMaterialCrossesFlutterMethodChannel": false,
      "localizedErrorsIncluded": false,
      "keychainUserPresencePolicyReady":
        userPresenceAccessControl["created"] as? Bool == true,
      "userPresenceAccessControl": userPresenceAccessControl,
      "secretStoreContract": Self.mobileRelaySecretStoreContract,
      "secretStoreBackend": Self.mobileRelaySecretStoreBackend,
      "secretStoreAccountPrefix": Self.mobileRelaySecretStoreAccountPrefix,
      "secretStoreNamespace": Self.mobileRelaySecretStoreNamespace,
      "secretStoreHandlePattern": "accountPrefix:namespace:key",
      "mobileRelayE2eeSecretStore": false,
      "rustSecretStoreSelectable": false,
      "selectionBlocker": "authenticated_capability_facts_not_implemented",
      "rawJsonSecretOverridesUsed": false,
      "sharedRustSecretStoreHandleContract": true,
      "portableConfigAuthority": "rust_generation_cas",
      "swiftPortableConfigReadWrite": false,
      "secretClasses": [
        "endpointPrivateKey",
        "signingKey",
        "signedPrekeyPrivateKey",
        "oneTimePrekeyPrivateKey",
        "oneTimeMlKem1024PrekeySeed",
        "pairingSecret",
        "pairwiseSessionSnapshot"
      ],
      "secretFields": [
        "privateKeyBase64url",
        "signingKeyBase64url",
        "signedPrekeyPrivateKeyBase64url",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "pairingSecretBase64url"
      ],
      "implementationStatus":
        "callback_contract_fail_closed_pending_authenticated_capability_facts"
    ]
  }

  func writeMobileRelaySecret(
    _ secret: String,
    storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackWrite: Bool = false,
    updateItem: ([String: Any], [String: Any]) -> OSStatus = {
      SecItemUpdate($0 as CFDictionary, $1 as CFDictionary)
    },
    addItem: ([String: Any]) -> OSStatus = {
      SecItemAdd($0 as CFDictionary, nil)
    }
  ) throws {
    guard let data = secret.data(using: .utf8), !data.isEmpty else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
    }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: mobileRelaySecretService,
      kSecAttrAccount as String: storedAccount
    ]
    if let callbackContext {
      query[kSecUseAuthenticationContext as String] =
        callbackContext.localAuthenticationContext
      if callbackWrite {
        callbackContext.recordCallbackSecretWrite(authenticationContextAttached: true)
      } else {
        callbackContext.recordPreDispatchSecretWrite(authenticationContextAttached: true)
      }
    }

    let updateStatus = updateItem(query, [kSecValueData as String: data])
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
    }

    var accessError: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .userPresence,
        &accessError
      )
    else {
      throw accessError?.takeRetainedValue() as Error? ?? NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(errSecParam)
      )
    }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessControl as String] = access
    let addStatus = addItem(addQuery)
    if addStatus == errSecSuccess {
      return
    }
    if addStatus == errSecDuplicateItem {
      // Resolve an insert race with one more atomic update. A failed retry
      // leaves the already committed item intact.
      let retryStatus = updateItem(query, [kSecValueData as String: data])
      guard retryStatus == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(retryStatus))
      }
      return
    }
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
  }

  func readMobileRelaySecretFromStoredAccount(
    _ storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackRead: Bool = false,
    copyItem: ([String: Any], UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = {
      SecItemCopyMatching($0 as CFDictionary, $1)
    }
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
    let status = copyItem(query, &copied)
    if status == errSecItemNotFound {
      if callbackRead {
        callbackContext?.recordCallbackSecretReadNotFound()
      }
      return nil
    }
    guard status == errSecSuccess else {
      if callbackRead {
        callbackContext?.recordCallbackSecretReadError()
      }
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    guard
      let data = copied as? Data,
      let secret = String(data: data, encoding: .utf8),
      !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      if callbackRead {
        callbackContext?.recordCallbackSecretReadError()
      }
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
    }
    if callbackRead {
      callbackContext?.recordCallbackSecretReadFound()
    }
    return secret
  }

  func deleteMobileRelaySecretAccount(
    _ storedAccount: String,
    callbackContext: SecureMeshIosSecretStoreCallbackContext? = nil,
    callbackDelete: Bool = false,
    deleteItem: ([String: Any]) -> OSStatus = {
      SecItemDelete($0 as CFDictionary)
    }
  ) throws {
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
    let status = deleteItem(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
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
      UnsafePointer<CChar>?,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32 = { context, namespace, key, valueOut in
      guard let valueOut else {
        return Int32(LICO_SECURE_MESH_SECRET_GET_ERROR)
      }
      valueOut.pointee = nil
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
          return Int32(LICO_SECURE_MESH_SECRET_GET_NOT_FOUND)
        }
        guard let allocated = strdup(secret) else {
          return Int32(LICO_SECURE_MESH_SECRET_GET_ERROR)
        }
        valueOut.pointee = allocated
        return Int32(LICO_SECURE_MESH_SECRET_GET_FOUND)
      } catch {
        return Int32(LICO_SECURE_MESH_SECRET_GET_ERROR)
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
        try bridge.deleteMobileRelaySecretAccount(
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
