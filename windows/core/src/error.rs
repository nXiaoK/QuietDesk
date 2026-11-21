use std::io;

/// A failure that ends a connection or rejects an operation. The text is shown to the user.
#[derive(Debug, thiserror::Error)]
pub enum DeskError {
    /// The peer or the user supplied something the protocol does not allow.
    #[error("{0}")]
    Invalid(String),
    /// The network path failed before or after the session was established.
    #[error("{0}")]
    Network(String),
    /// The TLS handshake failed; with a pre-shared key this usually means the pairing codes differ.
    #[error("{0}")]
    Pairing(String),
    /// A local component (capture, codec, clipboard) could not do what the session needed.
    #[error("{0}")]
    Platform(String),
}

impl DeskError {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }

    pub fn platform(message: impl Into<String>) -> Self {
        Self::Platform(message.into())
    }

    /// Whether connecting again without changing anything could succeed.
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::Network(_) | Self::Platform(_))
    }
}

impl From<io::Error> for DeskError {
    fn from(error: io::Error) -> Self {
        let reason = match error.kind() {
            io::ErrorKind::ConnectionRefused => "对方拒绝连接，可能已关闭共享或应用，请确认共享状态、地址和端口".to_string(),
            io::ErrorKind::TimedOut => "建立连接超时，请检查地址或远端状态".to_string(),
            io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionAborted | io::ErrorKind::BrokenPipe => {
                "对方已断开连接".to_string()
            }
            _ => format!("网络错误：{error}"),
        };
        Self::Network(reason)
    }
}

pub type Result<T> = std::result::Result<T, DeskError>;
