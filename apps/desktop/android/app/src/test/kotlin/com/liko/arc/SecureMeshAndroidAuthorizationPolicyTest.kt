package com.liko.arc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidAuthorizationPolicyTest {
    @Test
    fun publicBridgeActionsDoNotRequireAuthentication() {
        assertFalse(
            SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(
                "secure_mesh.android.userAuthentication.request"
            )
        )
        assertFalse(
            SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(
                "secure_mesh.android.userAuthentication.status"
            )
        )
        assertFalse(
            SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(
                "secure_mesh.android.status"
            )
        )
    }

    @Test
    fun credentialAndKeyActionsRequireAuthentication() {
        listOf(
            "mobile.provider.credential.set",
            "mobile.provider.credential.delete",
            "mobile.provider.credential.status",
            "mobile.provider.chat.send",
            "mobile.relay.pairing.claim",
            "mobile.relay.commands.createSecure",
            "secure_mesh.deviceTrust.rotate",
            "secure_mesh.deviceTrust.revoke"
        ).forEach { action ->
            assertTrue(
                action,
                SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action)
            )
            assertTrue(
                action,
                SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                    action,
                    interactionAuthorized = true
                )
            )
            assertFalse(
                action,
                SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                    action,
                    interactionAuthorized = false
                )
            )
        }
    }

    @Test
    fun sensitiveActionsUseNoPromptWhenUserAuthenticationCapabilityIsNotSelected() {
        listOf(
            "mobile.provider.credential.set",
            "mobile.relay.pairing.claim",
            "secure_mesh.deviceTrust.rotate"
        ).forEach { action ->
            assertFalse(
                action,
                SecureMeshAndroidAuthorizationPolicy.requiresSelectedUserAuthentication(
                    action,
                    userAuthenticationCapabilitySelected = false
                )
            )
            assertTrue(
                action,
                SecureMeshAndroidAuthorizationPolicy.requiresSelectedUserAuthentication(
                    action,
                    userAuthenticationCapabilitySelected = true
                )
            )
        }
    }

    @Test
    fun unknownActionsFailClosed() {
        listOf("", "future.credential.export", "mobile.relay.futureSensitiveAction")
            .forEach { action ->
                assertTrue(
                    action,
                    SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action)
                )
                assertTrue(
                    action,
                    SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                        action,
                        interactionAuthorized = true
                    )
                )
                assertFalse(
                    action,
                    SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                        action,
                        interactionAuthorized = false
                    )
                )
            }
    }

    @Test
    fun passiveOAuthCallbackCannotStartOrExtendAuthentication() {
        val action = "mobile.provider.oauth.completeCallback"
        assertTrue(SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action))
        assertFalse(
            SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                action,
                interactionAuthorized = true
            )
        )
    }

    @Test
    fun promptStrategyUsesCombinedPromptOnlyWhenStrongBiometricIsActuallyAvailable() {
        assertEquals(
            SecureMeshAndroidPromptStrategy.STRONG_BIOMETRIC_OR_DEVICE_CREDENTIAL,
            SecureMeshAndroidAuthorizationPolicy.selectPromptStrategy(
                strongBiometricAvailable = true,
                combinedPromptAvailable = true,
                priorBiometricCompatibilityFailure = false
            )
        )
        assertEquals(
            SecureMeshAndroidPromptStrategy.DEVICE_CREDENTIAL,
            SecureMeshAndroidAuthorizationPolicy.selectPromptStrategy(
                strongBiometricAvailable = false,
                combinedPromptAvailable = true,
                priorBiometricCompatibilityFailure = false
            )
        )
    }

    @Test
    fun aPriorBiometricCompatibilityFailureSelectsCredentialOnTheNextUserAction() {
        assertEquals(
            SecureMeshAndroidPromptStrategy.DEVICE_CREDENTIAL,
            SecureMeshAndroidAuthorizationPolicy.selectPromptStrategy(
                strongBiometricAvailable = true,
                combinedPromptAvailable = true,
                priorBiometricCompatibilityFailure = true
            )
        )
    }
}
