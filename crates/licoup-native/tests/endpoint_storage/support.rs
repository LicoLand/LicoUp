//! Shared fixtures for the V7-P1 endpoint-storage evidence.
//!
//! Everything here is synthetic or isolated: a fixture file vault standing in
//! for the platform secret store, temporary roots, fixed clocks, and captured
//! carrier/receiver/effect boundaries. No real keychain, hardware key, user
//! database, or user content is touched.

#![allow(dead_code)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Result, anyhow};
use licoup_native::core::secure_mesh_secret_store::{
    SecretBytes, SecretStoreHandle, SecureMeshSecretStore,
};
use licoup_protocol_bindings::endpoint::IdentityPublic;
use licoup_protocol_bindings::provider::RustCryptoProvider;
use licoup_protocol_bindings::state::{
    ApplicationEffects, Clock, PacketCarrier, PlaintextReceiver, TrustFacts,
};
use licoup_protocol_bindings::{AuthorityInput, Error, ErrorCode, Stage, VerifiedProtocolLine};

/// Environment input naming the explicit read-only LicoArc Candidate artifact.
pub const AUTHORITY_BUNDLE_ENV: &str = "LICOARC_AUTHORITY_BUNDLE";
/// Marks a re-executed child of this test binary.
pub const CHILD_ROLE_ENV: &str = "V7_ENDPOINT_STORAGE_CHILD_ROLE";
/// Storage namespace used by the isolated tests.
pub const FIXTURE_NAMESPACE: &str = "licoup.endpoint-v7.storage.test";

// ---------------------------------------------------------------------------
// Temporary roots
// ---------------------------------------------------------------------------

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// One temporary directory that removes itself on drop.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(label: &str) -> Self {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "licoup-v7-endpoint-storage-{label}-{}-{sequence}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("temporary test root is creatable");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

// ---------------------------------------------------------------------------
// Fixture platform custody
// ---------------------------------------------------------------------------

/// A file-backed `SecureMeshSecretStore`.
///
/// This is the explicitly announced non-production stand-in for the platform
/// keychain: it exercises the same caller-owned custody port, the same
/// authorization sessions, and the same logical lifecycle, but it is plain
/// files in a temporary directory and it does **not** claim hardware custody.
pub struct FixtureVault {
    root: PathBuf,
}

impl FixtureVault {
    pub fn new(root: impl AsRef<Path>) -> Self {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root).expect("fixture vault root is creatable");
        Self { root }
    }

    pub fn path(&self) -> &Path {
        &self.root
    }

    fn path_for(&self, handle: &SecretStoreHandle) -> PathBuf {
        let namespace = handle.namespace().replace(':', "_");
        let key = handle.key().replace(':', "_");
        self.root.join(namespace).join(key)
    }
}

impl SecureMeshSecretStore for FixtureVault {
    fn backend(&self) -> &'static str {
        "fixture-file-vault"
    }

    fn supported(&self) -> bool {
        true
    }

    fn set_secret(&self, handle: &SecretStoreHandle, secret: SecretBytes) -> Result<()> {
        let path = self.path_for(handle);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("tmp");
        {
            let mut file = fs::File::create(&temporary)?;
            file.write_all(secret.expose_bytes())?;
            file.sync_all()?;
        }
        fs::rename(&temporary, &path)?;
        Ok(())
    }

    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<SecretBytes>> {
        let path = self.path_for(handle);
        match fs::read(&path) {
            Ok(bytes) => {
                Ok(Some(SecretBytes::try_from_bytes(bytes).map_err(|_| {
                    anyhow!("fixture vault holds invalid secret bytes")
                })?))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
        let path = self.path_for(handle);
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

/// Number of material files currently in a fixture vault.
pub fn fixture_material_count(vault: &FixtureVault) -> usize {
    fn walk(path: &Path, count: &mut usize) {
        let Ok(entries) = fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, count);
            } else if path.extension().is_none() {
                *count += 1;
            }
        }
    }
    let mut count = 0;
    walk(&vault.root, &mut count);
    count
}

// ---------------------------------------------------------------------------
// The pinned Candidate line
// ---------------------------------------------------------------------------

/// The explicitly supplied authority artifact must admit the pinned line.
///
/// The path is caller-provided through [`AUTHORITY_BUNDLE_ENV`]; by design
/// nothing here searches a sibling checkout.
pub fn admitted_line() -> Result<VerifiedProtocolLine, Error> {
    let path = std::env::var_os(AUTHORITY_BUNDLE_ENV)
        .ok_or_else(|| Error::terminal(ErrorCode::InvalidAuthorityInput, Stage::Admission))?;
    let bytes = fs::read(path)
        .map_err(|_| Error::terminal(ErrorCode::InvalidAuthorityInput, Stage::Admission))?;
    AuthorityInput::new(&bytes)
        .admit()
        .map_err(|_| Error::terminal(ErrorCode::InvalidAuthorityInput, Stage::Admission))
}

// ---------------------------------------------------------------------------
// Boundaries the SDK calls back into
// ---------------------------------------------------------------------------

/// A fixed clock inside the synthetic prekey validity window.
#[derive(Clone, Copy)]
pub struct FixedClock(pub u64);

impl Clock for FixedClock {
    fn now_unix_seconds(&self) -> Result<u64, Error> {
        Ok(self.0)
    }
}

/// Keeps the last packet a carrier was asked to send.
#[derive(Default)]
pub struct CaptureCarrier {
    pub packet: Vec<u8>,
    pub sends: usize,
}

impl PacketCarrier for CaptureCarrier {
    fn send(&mut self, packet: &[u8]) -> Result<(), Error> {
        self.packet = packet.to_vec();
        self.sends += 1;
        Ok(())
    }
}

/// Keeps the last plaintext released to the application boundary.
#[derive(Default)]
pub struct CaptureReceiver {
    pub plaintext: Vec<u8>,
    pub releases: usize,
}

impl PlaintextReceiver for CaptureReceiver {
    fn release(&mut self, plaintext: &[u8]) -> Result<(), Error> {
        self.plaintext = plaintext.to_vec();
        self.releases += 1;
        Ok(())
    }
}

#[derive(Default)]
pub struct NoEffects;

impl ApplicationEffects for NoEffects {
    fn apply(&mut self, _effect: &[u8]) -> Result<(), Error> {
        Ok(())
    }
}

/// Records the identity keys this client already trusts for one peer device.
///
/// A real platform reads them from its own trust record; the shape is the same.
pub struct RecordedIdentity {
    pub identity: IdentityPublic,
    pub profile: [u8; 32],
}

impl TrustFacts for RecordedIdentity {
    fn identity_key(
        &self,
        identity_state_digest: &[u8; 32],
        purpose: &'static str,
        profile: &[u8; 32],
    ) -> Result<Vec<u8>, Error> {
        if *identity_state_digest != self.identity.state_digest || *profile != self.profile {
            return Err(Error::terminal(
                ErrorCode::AuthenticationFailed,
                Stage::Validation,
            ));
        }
        match purpose {
            "ed25519-key-id" => Ok(self.identity.ed25519_key_id.to_vec()),
            "ed25519-public" => Ok(self.identity.ed25519_public.to_vec()),
            "ml-dsa-65-key-id" => Ok(self.identity.ml_dsa_65_key_id.to_vec()),
            "ml-dsa-65-public" => Ok(self.identity.ml_dsa_65_public.clone()),
            _ => Err(Error::terminal(
                ErrorCode::AuthenticationFailed,
                Stage::Validation,
            )),
        }
    }
}

/// Synthetic prekey bundle identities used by the harness.
pub fn synthetic_identity(
    marker: u8,
    ed25519_public: [u8; 32],
    ml_dsa_65_public: Vec<u8>,
) -> IdentityPublic {
    IdentityPublic {
        state_digest: [marker; 32],
        ed25519_key_id: [marker.wrapping_add(1); 32],
        ed25519_public,
        ml_dsa_65_key_id: [marker.wrapping_add(2); 32],
        ml_dsa_65_public,
    }
}

// ---------------------------------------------------------------------------
// Child-process plumbing for the hard-death case
// ---------------------------------------------------------------------------

/// Paths and role labels handed to a re-executed child.
pub struct ChildSpec {
    pub role: &'static str,
    pub root: PathBuf,
    pub vault: PathBuf,
    pub marker: PathBuf,
}

/// Re-executes this test binary as an ignored child case and waits for its
/// `ready` line, then kills it with SIGKILL (no destructors, no graceful
/// close, no lock release by the child).
pub fn spawn_and_kill_child(spec: &ChildSpec, exact_test: &str) -> ChildStatus {
    let current = std::env::current_exe().expect("current test binary");
    let mut child = Command::new(current)
        .args(["--ignored", "--exact", exact_test, "--nocapture"])
        .env(CHILD_ROLE_ENV, spec.role)
        .env("V7_ENDPOINT_STORAGE_CHILD_ROOT", &spec.root)
        .env("V7_ENDPOINT_STORAGE_CHILD_VAULT", &spec.vault)
        .env("V7_ENDPOINT_STORAGE_CHILD_MARKER", &spec.marker)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("child test process starts");

    let stdout = child.stdout.take().expect("child stdout is piped");
    let mut reader = BufReader::new(stdout);
    let mut observed = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        let Ok(read) = reader.read_line(&mut line) else {
            break;
        };
        if read == 0 {
            break;
        }
        observed.push(line.trim().to_string());
        if line.trim() == "ready" {
            break;
        }
    }
    let status = kill_and_wait(&mut child);
    let marker = fs::read_to_string(&spec.marker).unwrap_or_default();
    ChildStatus {
        killed: status,
        observed,
        marker,
    }
}

fn kill_and_wait(child: &mut Child) -> bool {
    let killed = child.kill().is_ok();
    let _ = child.wait();
    killed
}

pub struct ChildStatus {
    pub killed: bool,
    pub observed: Vec<String>,
    pub marker: String,
}

/// Environment accessors for the child side.
pub fn child_value(key: &str) -> Option<String> {
    std::env::var(key).ok()
}

pub fn child_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).map(PathBuf::from)
}

/// Reads a prekey bundle and session accept pair from the child marker file so
/// the parent can assert what the killed process had committed.
pub fn parse_marker(marker: &str) -> Vec<(String, String)> {
    marker
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

pub fn synthetic_seed(marker: u8) -> [u8; 32] {
    [marker; 32]
}

pub fn synthetic_ml_kem_seed(marker: u8) -> [u8; 64] {
    [marker; 64]
}

/// Lowercase hex, used only for synthetic public keys in evidence.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[allow(dead_code)]
pub fn assert_code(error: &Error, code: ErrorCode) {
    assert_eq!(error.code, code, "unexpected SDK refusal {error}");
}

#[allow(dead_code)]
pub fn rust_crypto() -> RustCryptoProvider {
    RustCryptoProvider
}
