use std::fmt;

use zeroize::Zeroize;

pub const MAX_SECRET_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecretBytesError {
    Empty,
    Oversize,
    NotUtf8,
}

impl fmt::Display for SecretBytesError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Empty => "secure_mesh_secret_empty",
            Self::Oversize => "secure_mesh_secret_oversize",
            Self::NotUtf8 => "secure_mesh_secret_not_utf8",
        })
    }
}

impl std::error::Error for SecretBytesError {}

// The zeroize observation seam is read by callers outside this crate — the
// secret-store platform tests and the relay secret-material probe — so it is
// carried as the acceptance feature rather than as `cfg(test)`, which is false
// for a dependency. `licoup-native`'s dev-dependencies enable that feature.
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
#[derive(Clone, Default)]
pub struct SecretZeroizeProbe {
    observations: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
impl SecretZeroizeProbe {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observations(&self) -> Vec<Vec<u8>> {
        self.observations
            .lock()
            .map(|values| values.clone())
            .unwrap_or_default()
    }

    fn observe(&self, bytes: &[u8]) {
        if let Ok(mut observations) = self.observations.lock() {
            observations.push(bytes.to_vec());
        }
    }
}

pub struct SecretBytes {
    bytes: Vec<u8>,
    #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
    zeroize_probe: Option<SecretZeroizeProbe>,
}

impl SecretBytes {
    pub fn try_from_bytes(mut bytes: Vec<u8>) -> Result<Self, SecretBytesError> {
        if let Err(error) = Self::validate(&bytes) {
            bytes.zeroize();
            return Err(error);
        }
        Ok(Self {
            bytes,
            #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
            zeroize_probe: None,
        })
    }

    pub fn try_from_string(value: String) -> Result<Self, SecretBytesError> {
        Self::try_from_bytes(value.into_bytes())
    }

    fn validate(bytes: &[u8]) -> Result<(), SecretBytesError> {
        if bytes.is_empty() {
            return Err(SecretBytesError::Empty);
        }
        if bytes.len() > MAX_SECRET_BYTES {
            return Err(SecretBytesError::Oversize);
        }
        Ok(())
    }

    pub fn expose_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn expose_utf8(&self) -> Result<&str, SecretBytesError> {
        std::str::from_utf8(&self.bytes).map_err(|_| SecretBytesError::NotUtf8)
    }

    pub fn copy_for_persistent_read(&self) -> Self {
        Self::try_from_bytes(self.bytes.to_vec()).expect("validated secret bytes remain bounded")
    }

    #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
    pub fn try_from_bytes_with_test_zeroize_probe(
        mut bytes: Vec<u8>,
        zeroize_probe: SecretZeroizeProbe,
    ) -> Result<Self, SecretBytesError> {
        if let Err(error) = Self::validate(&bytes) {
            bytes.zeroize();
            zeroize_probe.observe(&bytes);
            return Err(error);
        }
        Ok(Self {
            bytes,
            zeroize_probe: Some(zeroize_probe),
        })
    }

    /// Attaches a zeroize observation probe to already-admitted secret bytes.
    ///
    /// The caller is the relay's secret-material fixture, which lives in
    /// `licoup-native`; the seam therefore crosses the crate boundary.
    #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
    pub fn attach_test_zeroize_probe(&mut self, zeroize_probe: SecretZeroizeProbe) {
        self.zeroize_probe = Some(zeroize_probe);
    }
}

impl fmt::Debug for SecretBytes {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretBytes([redacted])")
    }
}

impl Zeroize for SecretBytes {
    fn zeroize(&mut self) {
        if self.bytes.is_empty() {
            return;
        }
        self.bytes.as_mut_slice().zeroize();
        #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
        if let Some(probe) = &self.zeroize_probe {
            probe.observe(&self.bytes);
        }
        self.bytes.clear();
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        self.zeroize();
    }
}
