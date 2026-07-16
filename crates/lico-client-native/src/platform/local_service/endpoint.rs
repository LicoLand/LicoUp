#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServeEndpoint {
    pub host: String,
    pub port: u16,
    pub attach_url: String,
}

impl ServeEndpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        let host = host.into();
        Self {
            attach_url: format!("http://{}:{}", host, port),
            host,
            port,
        }
    }
}
