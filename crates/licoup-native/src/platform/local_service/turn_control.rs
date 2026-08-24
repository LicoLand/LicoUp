//! Bounded active-turn registry for native loopback serve APIs.

use super::http;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use url::Url;

const MAX_ACTIVE_TURNS: usize = 128;
const CONTROL_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

pub(in crate::platform) type ControlFailureObserver =
    Arc<dyn Fn(http::HttpFailure) + Send + Sync + 'static>;

#[derive(Clone)]
struct ActiveTurn {
    abort_url: String,
    generation: u64,
    failure_observer: Option<ControlFailureObserver>,
}

pub(in crate::platform) struct ActiveTurnGuard {
    key: (String, String),
    generation: u64,
}

static ACTIVE_TURNS: OnceLock<Mutex<HashMap<(String, String), ActiveTurn>>> = OnceLock::new();
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn active_turns() -> &'static Mutex<HashMap<(String, String), ActiveTurn>> {
    ACTIVE_TURNS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(in crate::platform) fn register(
    driver_id: &str,
    attach_url: &str,
    session_id: &str,
    failure_observer: Option<ControlFailureObserver>,
) -> Result<ActiveTurnGuard, ()> {
    if driver_id.is_empty()
        || driver_id.len() > 64
        || session_id.is_empty()
        || session_id.len() > 256
    {
        return Err(());
    }
    let abort_url = session_action_url(attach_url, session_id, "abort")?;
    let generation = NEXT_GENERATION.fetch_add(1, Ordering::Relaxed);
    let key = (driver_id.to_owned(), session_id.to_owned());
    let mut turns = active_turns().lock().map_err(|_| ())?;
    if turns.len() >= MAX_ACTIVE_TURNS && !turns.contains_key(&key) {
        return Err(());
    }
    turns.insert(
        key.clone(),
        ActiveTurn {
            abort_url,
            generation,
            failure_observer,
        },
    );
    Ok(ActiveTurnGuard { key, generation })
}

pub(in crate::platform) fn cancel(driver_id: &str, session_id: &str) -> ControlDisposition {
    if driver_id.is_empty() || session_id.is_empty() {
        return ControlDisposition::SessionUnavailable;
    }
    let active_turn = active_turns().lock().ok().and_then(|turns| {
        turns
            .get(&(driver_id.to_owned(), session_id.to_owned()))
            .cloned()
    });
    let Some(active_turn) = active_turn else {
        return ControlDisposition::NoActiveTurn;
    };
    match http::post_json(&active_turn.abort_url, &json!({}), CONTROL_TIMEOUT) {
        Ok(response) if accepted(&response) => ControlDisposition::Accepted,
        Ok(_) => ControlDisposition::NoActiveTurn,
        Err(failure) => {
            if let Some(observer) = active_turn.failure_observer {
                observer(failure);
            }
            ControlDisposition::TransportUnavailable
        }
    }
}

fn accepted(response: &Value) -> bool {
    response.as_bool() == Some(true)
        || response.get("ok").and_then(Value::as_bool) == Some(true)
        || response.get("aborted").and_then(Value::as_bool) == Some(true)
}

fn session_action_url(base: &str, session_id: &str, action: &str) -> Result<String, ()> {
    let mut url = Url::parse(base).map_err(|_| ())?;
    if !crate::platform::url_security::is_https_or_loopback_http_url(base) {
        return Err(());
    }
    {
        let mut segments = url.path_segments_mut().map_err(|_| ())?;
        segments.pop_if_empty();
        segments.push("session").push(session_id).push(action);
    }
    Ok(url.into())
}

impl Drop for ActiveTurnGuard {
    fn drop(&mut self) {
        if let Ok(mut turns) = active_turns().lock()
            && turns
                .get(&self.key)
                .is_some_and(|turn| turn.generation == self.generation)
        {
            turns.remove(&self.key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn read_complete_request(stream: &mut impl Read) -> Vec<u8> {
        let mut request = Vec::with_capacity(512);
        let mut chunk = [0_u8; 512];
        loop {
            let size = stream.read(&mut chunk).unwrap();
            assert!(size > 0, "HTTP request closed before its body completed");
            request.extend_from_slice(&chunk[..size]);
            assert!(request.len() <= 2048, "HTTP request exceeded test bound");
            let Some(header_end) = request.windows(4).position(|part| part == b"\r\n\r\n") else {
                continue;
            };
            let header_end = header_end + 4;
            let headers = String::from_utf8_lossy(&request[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if request.len() >= header_end.saturating_add(content_length) {
                return request;
            }
        }
    }

    #[test]
    fn control_url_encodes_the_session_as_one_path_segment() {
        let url =
            session_action_url("http://127.0.0.1:4096", "session/with space", "abort").unwrap();
        assert_eq!(
            url,
            "http://127.0.0.1:4096/session/session%2Fwith%20space/abort"
        );
    }

    #[test]
    fn active_turn_abort_is_bounded_and_unregistered_on_drop() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let request = read_complete_request(&mut stream);
            let request = String::from_utf8_lossy(&request);
            assert!(request.starts_with("POST /session/session-1/abort "));
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntrue",
                )
                .unwrap();
        });
        let guard = register(
            "test-serve-driver",
            &format!("http://{address}"),
            "session-1",
            None,
        )
        .unwrap();
        assert_eq!(
            cancel("test-serve-driver", "session-1"),
            ControlDisposition::Accepted
        );
        server.join().unwrap();
        drop(guard);
        assert_eq!(
            cancel("test-serve-driver", "session-1"),
            ControlDisposition::NoActiveTurn
        );
    }

    #[test]
    fn control_http_failure_is_projected_to_the_active_turn_owner() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let _ = read_complete_request(&mut stream);
            stream
                .write_all(
                    b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
                )
                .unwrap();
        });
        let observed = Arc::new(Mutex::new(None));
        let projected = Arc::clone(&observed);
        let guard = register(
            "test-failing-serve-driver",
            &format!("http://{address}"),
            "session-2",
            Some(Arc::new(move |failure| {
                *projected.lock().unwrap() = Some(failure);
            })),
        )
        .unwrap();

        assert_eq!(
            cancel("test-failing-serve-driver", "session-2"),
            ControlDisposition::TransportUnavailable
        );
        server.join().unwrap();
        assert_eq!(
            *observed.lock().unwrap(),
            Some(http::HttpFailure::Status(500))
        );
        drop(guard);
    }
}
