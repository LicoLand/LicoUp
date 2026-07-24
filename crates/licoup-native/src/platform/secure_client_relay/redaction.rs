use super::contract::{SecureClientRelayAuth, SecureClientRelayHttpError};

impl std::fmt::Display for SecureClientRelayAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SecureClientRelayAuth([redacted])")
    }
}

impl std::fmt::Debug for SecureClientRelayAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SecureClientRelayAuth([redacted])")
    }
}

impl std::fmt::Display for SecureClientRelayHttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "secure client relay {} failed with status {} and code {}",
            self.operation, self.status, self.code
        )
    }
}

impl std::error::Error for SecureClientRelayHttpError {}
