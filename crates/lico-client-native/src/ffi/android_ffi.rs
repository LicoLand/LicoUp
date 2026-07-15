use std::collections::BTreeSet;
use std::ffi::c_void;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow, ensure};
use jni::JNIEnv;
use jni::JavaVM;
use jni::objects::{GlobalRef, JObject, JString, JValue};
use jni::sys::jstring;
use serde_json::json;

use crate::core::secure_mesh_capability::{
    CapabilityFact, CapabilityFactState, CapabilityScope, SecurityCapability, capability_catalog,
};
use crate::platform::secure_mesh_capability_probe::{
    CAPABILITY_PROBE_SCHEMA_VERSION, CapabilityProbeSnapshot,
};
use crate::platform::secure_mesh_secret_store::{SecretStoreHandle, SecureMeshSecretStore};

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_liko_arc_MainActivity_nativeSecureMeshRuntimeSelfTest(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    i32::from(crate::ffi::secure_mesh_mobile_ffi::runtime_self_test())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_liko_arc_MainActivity_nativeSecureMeshRuntimeFeatureFlags(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    crate::ffi::secure_mesh_mobile_ffi::runtime_feature_flags()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_liko_arc_MainActivity_nativeSecureMeshRuntimeProtocolHash(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    crate::ffi::secure_mesh_mobile_ffi::runtime_protocol_hash()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_liko_arc_MainActivity_nativeSecureMeshJson(
    mut env: JNIEnv,
    _this: JObject,
    request_json: JString,
    files_dir: JString,
    secret_store_bridge: JObject,
) -> jstring {
    let response =
        match android_secure_mesh_json(&mut env, &secret_store_bridge, request_json, files_dir) {
            Ok(value) => value,
            Err(_error) => json!({
                "ok": false,
                "code": "android_secure_mesh_native_json_failed",
                "error": "Secure Mesh native request failed.",
                "errorDetailRedacted": true,
            }),
        };
    let serialized = serde_json::to_string(&response).unwrap_or_else(|_error| {
        r#"{"ok":false,"code":"android_secure_mesh_json_serialize_failed","error":"Secure Mesh response serialization failed.","errorDetailRedacted":true}"#.to_string()
    });
    env.new_string(serialized)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

fn android_secure_mesh_json(
    env: &mut JNIEnv,
    secret_store_bridge: &JObject,
    request_json: JString,
    files_dir: JString,
) -> anyhow::Result<serde_json::Value> {
    let request_text: String = env.get_string(&request_json)?.into();
    let files_dir_text: String = env.get_string(&files_dir)?.into();
    let pairwise_secret_store: Arc<dyn SecureMeshSecretStore> =
        Arc::new(AndroidJniSecretStore::new(env, secret_store_bridge)?);
    crate::ffi::secure_mesh_mobile_ffi::dispatch_json_with_files_dir_and_pairwise_secret_store(
        &request_text,
        &files_dir_text,
        "android_secure_mesh_native_json_action_unsupported",
        pairwise_secret_store,
    )
}

struct AndroidJniSecretStore {
    java_vm: JavaVM,
    secret_store: GlobalRef,
    selected_backend: AndroidSelectedCustodyBackend,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AndroidSelectedCustodyBackend {
    KeyStore,
    MemoryOnlyEphemeral,
}

impl AndroidSelectedCustodyBackend {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "android-keystore" => Ok(Self::KeyStore),
            "memory-only-ephemeral" => Ok(Self::MemoryOnlyEphemeral),
            _ => Err(anyhow!("android selected custody backend is invalid")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::KeyStore => "android-keystore",
            Self::MemoryOnlyEphemeral => "memory-only-ephemeral",
        }
    }
}

impl AndroidJniSecretStore {
    fn new(env: &mut JNIEnv, secret_store: &JObject) -> Result<Self> {
        let selected_backend = env
            .call_method(
                secret_store,
                "secureMeshAndroidSelectedCustodyBackend",
                "()Ljava/lang/String;",
                &[],
            )
            .context("android selected custody backend call failed")?
            .l()
            .context("android selected custody backend return failed")?;
        ensure!(
            !selected_backend.is_null(),
            "android selected custody backend is unavailable"
        );
        let selected_backend: String = env
            .get_string(&JString::from(selected_backend))
            .context("android selected custody backend string failed")?
            .into();
        Ok(Self {
            java_vm: env
                .get_java_vm()
                .context("android secret store JavaVM unavailable")?,
            secret_store: env
                .new_global_ref(secret_store)
                .context("android secret store bridge reference unavailable")?,
            selected_backend: AndroidSelectedCustodyBackend::parse(&selected_backend)?,
        })
    }

    fn call_set(&self, handle: &SecretStoreHandle, secret: &str) -> Result<bool> {
        let mut env = self
            .java_vm
            .attach_current_thread()
            .context("android secret store thread attach failed")?;
        let namespace = JObject::from(
            env.new_string(handle.namespace())
                .context("android secret store namespace bridge failed")?,
        );
        let key = JObject::from(
            env.new_string(handle.key())
                .context("android secret store key bridge failed")?,
        );
        let secret = JObject::from(
            env.new_string(secret)
                .context("android secret store secret bridge failed")?,
        );
        env.call_method(
            self.secret_store.as_obj(),
            "secureMeshAndroidSecretStoreSet",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z",
            &[
                JValue::Object(&namespace),
                JValue::Object(&key),
                JValue::Object(&secret),
            ],
        )
        .context("android secret store set call failed")?
        .z()
        .context("android secret store set return failed")
    }

    fn call_get(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
        let mut env = self
            .java_vm
            .attach_current_thread()
            .context("android secret store thread attach failed")?;
        let namespace = JObject::from(
            env.new_string(handle.namespace())
                .context("android secret store namespace bridge failed")?,
        );
        let key = JObject::from(
            env.new_string(handle.key())
                .context("android secret store key bridge failed")?,
        );
        let value = env
            .call_method(
                self.secret_store.as_obj(),
                "secureMeshAndroidSecretStoreGet",
                "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                &[JValue::Object(&namespace), JValue::Object(&key)],
            )
            .context("android secret store get call failed")?
            .l()
            .context("android secret store get return failed")?;
        if value.is_null() {
            return Ok(None);
        }
        let text: String = env
            .get_string(&JString::from(value))
            .context("android secret store get string failed")?
            .into();
        if text.trim().is_empty() {
            Ok(None)
        } else {
            Ok(Some(text))
        }
    }

    fn call_delete(&self, handle: &SecretStoreHandle) -> Result<bool> {
        let mut env = self
            .java_vm
            .attach_current_thread()
            .context("android secret store thread attach failed")?;
        let namespace = JObject::from(
            env.new_string(handle.namespace())
                .context("android secret store namespace bridge failed")?,
        );
        let key = JObject::from(
            env.new_string(handle.key())
                .context("android secret store key bridge failed")?,
        );
        env.call_method(
            self.secret_store.as_obj(),
            "secureMeshAndroidSecretStoreDelete",
            "(Ljava/lang/String;Ljava/lang/String;)Z",
            &[JValue::Object(&namespace), JValue::Object(&key)],
        )
        .context("android secret store delete call failed")?
        .z()
        .context("android secret store delete return failed")
    }

    fn call_capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        let mut env = self
            .java_vm
            .attach_current_thread()
            .context("android capability probe thread attach failed")?;
        let value = env
            .call_method(
                self.secret_store.as_obj(),
                "secureMeshAndroidCapabilityProbeJson",
                "()Ljava/lang/String;",
                &[],
            )
            .context("android capability probe call failed")?
            .l()
            .context("android capability probe return failed")?;
        ensure!(
            !value.is_null(),
            "android capability probe returned no snapshot"
        );
        let source: String = env
            .get_string(&JString::from(value))
            .context("android capability probe string failed")?
            .into();
        parse_android_capability_facts(&source)
    }
}

fn parse_android_capability_facts(source: &str) -> Result<Vec<CapabilityFact>> {
    let snapshot: CapabilityProbeSnapshot = serde_json::from_str(source)
        .map_err(|_| anyhow!("android capability probe schema is invalid"))?;
    ensure!(
        snapshot.schema_version == CAPABILITY_PROBE_SCHEMA_VERSION,
        "android capability probe schema version is unsupported"
    );
    let snapshot = CapabilityProbeSnapshot::new(snapshot.facts)?;
    let expected = capability_catalog()?
        .definitions()
        .filter(|definition| {
            definition.scope == CapabilityScope::LocalCustody && !definition.derived
        })
        .map(|definition| definition.capability)
        .collect::<BTreeSet<_>>();
    let actual = snapshot
        .facts
        .iter()
        .map(|fact| fact.capability)
        .collect::<BTreeSet<_>>();
    ensure!(
        actual == expected,
        "android capability probe does not classify every custody fact"
    );
    Ok(snapshot.facts)
}

impl SecureMeshSecretStore for AndroidJniSecretStore {
    fn backend(&self) -> &'static str {
        self.selected_backend.as_str()
    }

    fn supported(&self) -> bool {
        true
    }

    fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        let facts = self.call_capability_facts()?;
        validate_android_selected_backend_facts(self.selected_backend, &facts)?;
        Ok(facts)
    }

    fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
        ensure!(
            self.call_set(handle, secret)?,
            "android secret store write failed for {}",
            handle.key()
        );
        Ok(())
    }

    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
        self.call_get(handle)
            .map_err(|_error| anyhow!("android secret store read failed"))
    }

    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
        ensure!(
            self.call_delete(handle)?,
            "android secret store delete failed for {}",
            handle.key()
        );
        Ok(())
    }
}

fn validate_android_selected_backend_facts(
    selected_backend: AndroidSelectedCustodyBackend,
    facts: &[CapabilityFact],
) -> Result<()> {
    let fact_state = |capability| {
        facts
            .iter()
            .find(|fact| fact.capability == capability)
            .map(|fact| fact.state)
    };
    match selected_backend {
        AndroidSelectedCustodyBackend::KeyStore => ensure!(
            fact_state(SecurityCapability::OsSecureStore) == Some(CapabilityFactState::Supported)
                && fact_state(SecurityCapability::AndroidKeystore)
                    == Some(CapabilityFactState::Supported),
            "android selected KeyStore backend conflicts with capability evidence"
        ),
        AndroidSelectedCustodyBackend::MemoryOnlyEphemeral => ensure!(
            fact_state(SecurityCapability::OsSecureStore) != Some(CapabilityFactState::Supported)
                && fact_state(SecurityCapability::AndroidKeystore)
                    != Some(CapabilityFactState::Supported),
            "android memory-only custody conflicts with capability evidence"
        ),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_capability::{
        CapabilityEvidenceKind, CapabilityFactState, SecurityCapability,
    };

    fn complete_android_facts() -> Vec<CapabilityFact> {
        capability_catalog()
            .unwrap()
            .definitions()
            .filter(|definition| {
                definition.scope == CapabilityScope::LocalCustody && !definition.derived
            })
            .map(|definition| match definition.capability {
                SecurityCapability::OsSecureStore
                | SecurityCapability::SoftwareBacked
                | SecurityCapability::AndroidKeystore => CapabilityFact::supported(
                    definition.capability,
                    CapabilityEvidenceKind::GeneratedKeyInspection,
                ),
                _ => CapabilityFact::unavailable(
                    definition.capability,
                    CapabilityFactState::Unsupported,
                    CapabilityEvidenceKind::GeneratedKeyInspection,
                    "android_fixture_not_supported",
                )
                .unwrap(),
            })
            .collect()
    }

    #[test]
    fn android_ffi_self_test_covers_native_secure_mesh_runtime() {
        assert_eq!(
            crate::ffi::secure_mesh_mobile_ffi::runtime_feature_flags(),
            crate::ffi::secure_mesh_mobile_ffi::EXPECTED_FEATURES
        );
    }

    #[test]
    fn android_capability_snapshot_preserves_independent_exact_facts() {
        let source =
            serde_json::to_string(&CapabilityProbeSnapshot::new(complete_android_facts()).unwrap())
                .unwrap();
        let facts = parse_android_capability_facts(&source).unwrap();
        let by_capability = facts
            .iter()
            .map(|fact| (fact.capability, fact))
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(by_capability.len(), complete_android_facts().len());
        assert_eq!(
            by_capability[&SecurityCapability::OsSecureStore].state,
            CapabilityFactState::Supported
        );
        assert_eq!(
            by_capability[&SecurityCapability::SoftwareBacked].state,
            CapabilityFactState::Supported
        );
        assert_eq!(
            by_capability[&SecurityCapability::Strongbox].state,
            CapabilityFactState::Unsupported
        );
    }

    #[test]
    fn android_selected_custody_backend_is_exact_and_matches_capability_facts() {
        assert_eq!(
            AndroidSelectedCustodyBackend::parse("android-keystore").unwrap(),
            AndroidSelectedCustodyBackend::KeyStore
        );
        assert_eq!(
            AndroidSelectedCustodyBackend::parse("memory-only-ephemeral").unwrap(),
            AndroidSelectedCustodyBackend::MemoryOnlyEphemeral
        );
        assert!(AndroidSelectedCustodyBackend::parse("AndroidKeyStore").is_err());

        let key_store_facts = complete_android_facts();
        validate_android_selected_backend_facts(
            AndroidSelectedCustodyBackend::KeyStore,
            &key_store_facts,
        )
        .unwrap();
        assert!(
            validate_android_selected_backend_facts(
                AndroidSelectedCustodyBackend::MemoryOnlyEphemeral,
                &key_store_facts,
            )
            .is_err()
        );
        let memory_facts = key_store_facts
            .into_iter()
            .map(|fact| match fact.capability {
                SecurityCapability::OsSecureStore | SecurityCapability::AndroidKeystore => {
                    CapabilityFact::unavailable(
                        fact.capability,
                        CapabilityFactState::Unsupported,
                        CapabilityEvidenceKind::GeneratedKeyInspection,
                        "android_fixture_not_supported",
                    )
                    .unwrap()
                }
                _ => fact,
            })
            .collect::<Vec<_>>();
        validate_android_selected_backend_facts(
            AndroidSelectedCustodyBackend::MemoryOnlyEphemeral,
            &memory_facts,
        )
        .unwrap();
    }

    #[test]
    fn android_capability_snapshot_rejects_unknown_fields_and_versions() {
        let unknown = serde_json::json!({
            "schemaVersion": CAPABILITY_PROBE_SCHEMA_VERSION,
            "facts": [],
            "ready": true
        });
        assert!(parse_android_capability_facts(&unknown.to_string()).is_err());

        let stale = serde_json::json!({
            "schemaVersion": CAPABILITY_PROBE_SCHEMA_VERSION + 1,
            "facts": []
        });
        assert!(parse_android_capability_facts(&stale.to_string()).is_err());

        let incomplete = CapabilityProbeSnapshot::new(vec![CapabilityFact::supported(
            SecurityCapability::OsSecureStore,
            CapabilityEvidenceKind::RuntimeOperation,
        )])
        .unwrap();
        assert!(
            parse_android_capability_facts(&serde_json::to_string(&incomplete).unwrap()).is_err()
        );
    }
}
