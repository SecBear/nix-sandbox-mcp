//! Transport layer for daemon ↔ agent communication.
//!
//! Provides the `Transport` trait and length-prefixed JSON framing functions.
//! Phase 2b uses `StdioPipeTransport` (stdin/stdout pipes to jailed agent).
//! Phase 3 will add `VsockTransport` for microVM agents.

pub mod protocol;
pub mod stdio_pipe;

pub use protocol::{AgentRequest, AgentResponse};
pub use stdio_pipe::StdioPipeTransport;

use anyhow::Result;
use async_trait::async_trait;

/// Maximum message size (64 MB). Safety valve against malformed messages.
const MAX_MESSAGE_SIZE: u32 = 64 * 1024 * 1024;

/// Abstraction over daemon ↔ agent communication channels.
///
/// Implementations handle connection-specific details (pipes, vsock, etc.)
/// while the session manager works with this uniform interface.
#[async_trait]
pub trait Transport: Send + Sync {
    /// Send a request and wait for the response.
    ///
    /// Access is mutex-guarded internally — concurrent callers serialize.
    async fn request(&self, req: &AgentRequest) -> Result<AgentResponse>;

    /// Gracefully shut down the transport and the underlying agent process.
    async fn shutdown(&self) -> Result<()>;

    /// Check whether the underlying agent process is still alive.
    fn is_alive(&self) -> bool;
}

/// Write a length-prefixed message to a writer.
///
/// Format: [4-byte big-endian length][payload bytes]
pub async fn send_message<W: tokio::io::AsyncWriteExt + Unpin>(
    writer: &mut W,
    payload: &[u8],
) -> Result<()> {
    let len = u32::try_from(payload.len())
        .map_err(|_| anyhow::anyhow!("Message too large: {} bytes", payload.len()))?;
    anyhow::ensure!(
        len <= MAX_MESSAGE_SIZE,
        "Message exceeds max size: {len} > {MAX_MESSAGE_SIZE}"
    );

    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(payload).await?;
    writer.flush().await?;
    Ok(())
}

/// Read a length-prefixed message from a reader.
///
/// Returns the raw payload bytes. Enforces `MAX_MESSAGE_SIZE`.
pub async fn recv_message<R: tokio::io::AsyncReadExt + Unpin>(
    reader: &mut R,
) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf);

    anyhow::ensure!(
        len <= MAX_MESSAGE_SIZE,
        "Message exceeds max size: {len} > {MAX_MESSAGE_SIZE}"
    );

    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf).await?;
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn roundtrip_framing() {
        let payload = b"hello world";
        let mut buf = Vec::new();

        send_message(&mut buf, payload).await.unwrap();

        let mut cursor = std::io::Cursor::new(buf);
        let received = recv_message(&mut cursor).await.unwrap();
        assert_eq!(received, payload);
    }

    #[tokio::test]
    async fn empty_payload() {
        let mut buf = Vec::new();
        send_message(&mut buf, b"").await.unwrap();

        let mut cursor = std::io::Cursor::new(buf);
        let received = recv_message(&mut cursor).await.unwrap();
        assert!(received.is_empty());
    }

    #[tokio::test]
    async fn protocol_serialize_request() {
        let req = AgentRequest::Execute {
            id: "1".to_string(),
            interpreter: "python".to_string(),
            code: "print(42)".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"execute\""));
        assert!(json.contains("\"interpreter\":\"python\""));
    }

    #[tokio::test]
    async fn protocol_serialize_response() {
        let resp = AgentResponse::Result {
            id: "1".to_string(),
            stdout: "42\n".to_string(),
            stderr: String::new(),
            exit_code: 0,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"result\""));
        assert!(json.contains("\"exit_code\":0"));
    }

    #[tokio::test]
    async fn protocol_deserialize_ready() {
        let json = r#"{"type":"ready"}"#;
        let resp: AgentResponse = serde_json::from_str(json).unwrap();
        assert!(matches!(resp, AgentResponse::Ready));
    }
}
