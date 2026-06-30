pub fn is_https_or_loopback_http_url(value: &str) -> bool {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("https://") {
        return true;
    }
    is_loopback_http_url(trimmed)
}

pub fn is_loopback_http_url(value: &str) -> bool {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if !lower.starts_with("http://") {
        return false;
    }
    let after_scheme = &trimmed["http://".len()..];
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default()
        .trim();
    if authority.is_empty() {
        return false;
    }
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    let host = if let Some(rest) = host_port.strip_prefix('[') {
        match rest.split_once(']') {
            Some((host, _)) => host,
            None => return false,
        }
    } else {
        host_port.split(':').next().unwrap_or_default()
    }
    .trim()
    .trim_end_matches('.')
    .to_ascii_lowercase();
    matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1")
}

#[cfg(test)]
mod tests {
    use super::{is_https_or_loopback_http_url, is_loopback_http_url};

    #[test]
    fn accepts_https_or_exact_loopback_http_hosts() {
        assert!(is_https_or_loopback_http_url("https://example.com"));
        assert!(is_https_or_loopback_http_url(
            "http://127.0.0.1:7228/forward"
        ));
        assert!(is_https_or_loopback_http_url(
            "http://localhost:7228/forward"
        ));
        assert!(is_loopback_http_url("http://[::1]:7228/forward"));
    }

    #[test]
    fn rejects_prefix_spoofed_loopback_hosts() {
        assert!(!is_https_or_loopback_http_url(
            "http://127.0.0.1.evil.test/forward"
        ));
        assert!(!is_https_or_loopback_http_url(
            "http://localhost.evil.test/forward"
        ));
        assert!(!is_https_or_loopback_http_url(
            "http://127.0.0.1@evil.test/forward"
        ));
        assert!(!is_loopback_http_url("https://127.0.0.1:7228/forward"));
    }
}
