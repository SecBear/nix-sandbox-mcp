//! Agent protocol message types.
//!
//! Length-prefixed JSON protocol for daemon ↔ agent communication.
//! Messages are framed as: [4-byte BE length][JSON payload]

use serde::{Deserialize, Serialize};

/// Request sent from daemon to agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentRequest {
    /// Execute code in the specified interpreter.
    Execute {
        id: String,
        interpreter: String,
        code: String,
    },
    /// Graceful shutdown.
    Shutdown,
    /// Health check.
    Ping,
}

/// Response sent from agent to daemon.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentResponse {
    /// Agent is ready to accept requests (sent on startup).
    Ready,
    /// Execution result.
    Result {
        id: String,
        stdout: String,
        stderr: String,
        exit_code: i32,
    },
    /// Pong response to health check.
    Pong,
    /// Error response.
    Error { message: String },
}
