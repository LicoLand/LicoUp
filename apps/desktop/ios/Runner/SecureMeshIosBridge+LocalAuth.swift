import Foundation
import LocalAuthentication
import Security

extension SecureMeshIosBridge {
  func localAuthenticationStatus() -> [String: Any] {
    let context = LAContext()
    var error: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    return [
      "provider": "LocalAuthentication",
      "available": available,
      "policy": "deviceOwnerAuthentication",
      "biometryType": biometryTypeText(context.biometryType),
      "biometricDataHandledByApp": false,
      "appPasswordPromptUsed": false,
      "localizedErrorsIncluded": false,
      "userPresencePromptStarted": false,
      "errorCode": localAuthenticationErrorCode(error),
      "diagnosticCategory": localAuthenticationDiagnosticCategory(error)
    ]
  }

  func mobileRelayUserPresenceProof() -> [String: Any] {
    let context = LAContext()
    context.localizedReason = "Unlock Arc secure relay keys"
    var authError: NSError?
    let localAuthenticationAvailable = context.canEvaluatePolicy(
      .deviceOwnerAuthentication,
      error: &authError
    )
    let accessControl = userPresenceAccessControlCreationStatus()
    let account = "user-presence-proof-\(UUID().uuidString)"
    let secret = Data("ios-user-presence-proof-\(UUID().uuidString)".utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: mobileRelaySecretService,
      kSecAttrAccount as String: account
    ]
    var accessError: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .userPresence,
      &accessError
    )

    var addStatus: OSStatus = errSecParam
    if let access {
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = secret
      addQuery[kSecAttrAccessControl as String] = access
      addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    }

    let nonInteractive = copyUserPresenceProofItem(
      baseQuery: baseQuery,
      context: context,
      allowInteraction: false
    )
    let interactive = copyUserPresenceProofItem(
      baseQuery: baseQuery,
      context: context,
      allowInteraction: true
    )
    let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
    let nonInteractiveBlocked =
      nonInteractive.status == errSecInteractionNotAllowed ||
      nonInteractive.status == errSecAuthFailed
    let authenticated = interactive.status == errSecSuccess
    let failClosedWhenInteractionNotAllowed =
      nonInteractiveBlocked && nonInteractive.rawSecretMaterialReturned == false

    return [
      "ok": localAuthenticationAvailable &&
        access != nil &&
        addStatus == errSecSuccess &&
        failClosedWhenInteractionNotAllowed &&
        authenticated &&
        interactive.rawSecretMaterialReturned == true,
      "platform": "ios",
      "provider": "LocalAuthentication",
      "localAuthenticationAvailable": localAuthenticationAvailable,
      "policy": "deviceOwnerAuthentication",
      "biometryType": biometryTypeText(context.biometryType),
      "credentialEntrySurface": "ios_system_local_auth_prompt",
      "systemPromptSurface": "ios_system_local_auth_prompt",
      "physicalUserPresenceRequired": true,
      "systemCredentialPromptAvailable": localAuthenticationAvailable,
      "systemCredentialPromptStarted": addStatus == errSecSuccess,
      "systemCredentialPromptCompleted": authenticated,
      "systemCredentialPromptResult": authenticated
        ? "authenticated"
        : securityDiagnosticCategory(interactive.status),
      "userPresencePromptStarted": addStatus == errSecSuccess,
      "authenticated": authenticated,
      "secretReadAfterUserPresence": authenticated,
      "accessibility": "WhenUnlockedThisDeviceOnly",
      "accessControl": "userPresence",
      "keychainUserPresencePolicyReady": access != nil,
      "userPresenceAccessControl": accessControl,
      "nonInteractiveReadBlocked": nonInteractiveBlocked,
      "failClosedWhenInteractionNotAllowed": failClosedWhenInteractionNotAllowed,
      "failClosedOnUserCancel":
        interactive.status == errSecUserCanceled &&
        interactive.rawSecretMaterialReturned == false,
      "failClosedOnAuthFailed":
        interactive.status == errSecAuthFailed &&
        interactive.rawSecretMaterialReturned == false,
      "cancelOrAuthFailureProbeRequiredForProduction": true,
      "cancelOrAuthFailureProbeReady":
        (interactive.status == errSecUserCanceled || interactive.status == errSecAuthFailed) &&
        interactive.rawSecretMaterialReturned == false,
      "appPasswordPromptUsed": false,
      "appCredentialPromptUsed": false,
      "biometricDataHandledByApp": false,
      "protectedKeychainValueReturnedToAppMemory": authenticated,
      "rawSecretMaterialIncluded": false,
      "localizedErrorsIncluded": false,
      "addStatus": securityStatusText(addStatus),
      "addDiagnosticCategory": securityDiagnosticCategory(addStatus),
      "nonInteractiveReadStatus": securityStatusText(nonInteractive.status),
      "nonInteractiveReadDiagnosticCategory":
        securityDiagnosticCategory(nonInteractive.status),
      "interactiveReadStatus": securityStatusText(interactive.status),
      "interactiveReadDiagnosticCategory":
        securityDiagnosticCategory(interactive.status),
      "deleteStatus": securityStatusText(deleteStatus),
      "deleteDiagnosticCategory": securityDiagnosticCategory(deleteStatus),
      "localAuthenticationDiagnosticCategory":
        localAuthenticationDiagnosticCategory(authError),
      "productionReady": false
    ]
  }

  func copyUserPresenceProofItem(
    baseQuery: [String: Any],
    context: LAContext,
    allowInteraction: Bool
  ) -> (status: OSStatus, rawSecretMaterialReturned: Bool) {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    if allowInteraction {
      query[kSecUseOperationPrompt as String] = "Unlock Arc secure relay keys"
    } else {
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
    var copied: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &copied)
    return (status, copied != nil)
  }


  func userPresenceAccessControlCreationStatus() -> [String: Any] {
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .userPresence,
      &error
    )
    if access != nil {
      return [
        "created": true,
        "accessibility": "WhenUnlockedThisDeviceOnly",
        "accessControl": "userPresence",
        "diagnosticCategory": "ready",
        "localizedErrorsIncluded": false
      ]
    }
    let nsError = error.map { ($0.takeRetainedValue() as Error) as NSError }
    return [
      "created": false,
      "accessibility": "WhenUnlockedThisDeviceOnly",
      "accessControl": "userPresence",
      "errorCode": nsError.map { "\($0.code)" } ?? "",
      "diagnosticCategory": "access_control_creation_failed",
      "localizedErrorsIncluded": false
    ]
  }

  func localAuthenticationErrorCode(_ error: NSError?) -> String {
    guard let error else {
      return ""
    }
    return "la_error_\(error.code)"
  }

  func localAuthenticationDiagnosticCategory(_ error: NSError?) -> String {
    guard let error else {
      return "ready"
    }
    guard let code = LAError.Code(rawValue: error.code) else {
      return "local_authentication_unavailable"
    }
    switch code {
    case .biometryNotAvailable:
      return "biometry_not_available"
    case .biometryNotEnrolled:
      return "biometry_not_enrolled"
    case .passcodeNotSet:
      return "device_passcode_not_set"
    case .biometryLockout:
      return "biometry_lockout"
    case .userCancel:
      return "user_cancelled"
    case .userFallback:
      return "user_fallback_requested"
    case .systemCancel:
      return "system_cancelled"
    case .notInteractive:
      return "not_interactive"
    default:
      return "local_authentication_unavailable"
    }
  }


  func biometryTypeText(_ type: LABiometryType) -> String {
    switch type {
    case .none:
      return "none"
    case .touchID:
      return "touchID"
    case .faceID:
      return "faceID"
    case .opticID:
      return "opticID"
    @unknown default:
      return "unknown"
    }
  }
}
