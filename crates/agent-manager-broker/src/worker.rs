//! Private JSON-RPC process boundary for the Python Claude worker.

use std::process::Stdio;

use serde_json::{Value, json};
use thiserror::Error;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use uuid::Uuid;

use crate::BROKER_VERSION;
use crate::framing::{BoundedFrame, read_bounded_line};
use crate::protocol::{ProviderRuntime, RequestId};

pub const WORKER_PROTOCOL_VERSION: u32 = 1;
pub const CLAUDE_COMPATIBILITY_PROFILE: &str = "claude-agent-sdk-v1";
pub const TESTED_CLAUDE_SDK_VERSION: &str = "0.2.152";
pub const TESTED_CLAUDE_CODE_VERSION: &str = "2.1.259";
const MAX_FRAME_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkerCommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl Default for WorkerCommandSpec {
    fn default() -> Self {
        Self {
            program: "python".to_owned(),
            args: vec![
                "-B".to_owned(),
                "-I".to_owned(),
                "-m".to_owned(),
                "agent_manager_claude_worker".to_owned(),
            ],
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkerInbound {
    pub id: Option<RequestId>,
    pub method: String,
    pub params: Value,
}

impl WorkerInbound {
    #[must_use]
    pub const fn is_callback(&self) -> bool {
        self.id.is_some()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkerRequestOutcome {
    pub result: Value,
    pub inbound: Vec<WorkerInbound>,
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("failed to spawn Claude worker: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Claude worker did not expose {0}")]
    MissingPipe(&'static str),
    #[error("Claude worker I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("Claude worker emitted invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Claude worker frame exceeds the size limit")]
    FrameTooLarge,
    #[error("Claude worker closed its protocol stream")]
    Closed,
    #[error("Claude worker protocol error {code}: {message}")]
    Response { code: i64, message: String },
    #[error("Claude worker emitted an unexpected protocol frame")]
    UnexpectedFrame,
    #[error("Claude worker response omitted {0}")]
    MissingField(&'static str),
    #[error("Claude worker protocol negotiation failed: {0}")]
    Negotiation(&'static str),
}

pub struct ClaudeWorker {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_request_id: u64,
}

impl ClaudeWorker {
    pub fn spawn(spec: &WorkerCommandSpec) -> Result<Self, WorkerError> {
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(WorkerError::Spawn)?;
        let stdin = child
            .stdin
            .take()
            .ok_or(WorkerError::MissingPipe("stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or(WorkerError::MissingPipe("stdout"))?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            next_request_id: 1,
        })
    }

    pub async fn initialize(&mut self) -> Result<Value, WorkerError> {
        let nonce = Uuid::new_v4().simple().to_string();
        let outcome = self
            .request(
                "worker/initialize",
                json!({
                    "protocol_version": WORKER_PROTOCOL_VERSION,
                    "broker_version": BROKER_VERSION,
                    "nonce": nonce
                }),
            )
            .await?;
        if !outcome.inbound.is_empty() {
            return Err(WorkerError::Negotiation(
                "unexpected worker traffic during initialization",
            ));
        }
        if outcome
            .result
            .get("protocol_version")
            .and_then(Value::as_u64)
            != Some(u64::from(WORKER_PROTOCOL_VERSION))
        {
            return Err(WorkerError::Negotiation("protocol version mismatch"));
        }
        if outcome.result.get("nonce").and_then(Value::as_str) != Some(nonce.as_str()) {
            return Err(WorkerError::Negotiation("nonce mismatch"));
        }
        runtime_identity(&outcome.result)?;
        Ok(outcome.result)
    }

    pub async fn request(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<WorkerRequestOutcome, WorkerError> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or(WorkerError::UnexpectedFrame)?;
        self.write(&json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params
        }))
        .await?;

        let mut inbound = Vec::new();
        loop {
            let message = self.read().await?;
            if message.get("id").and_then(Value::as_u64) == Some(request_id)
                && message.get("method").is_none()
            {
                if let Some(error) = message.get("error") {
                    return Err(response_error(error));
                }
                let result = message
                    .get("result")
                    .cloned()
                    .ok_or(WorkerError::MissingField("result"))?;
                return Ok(WorkerRequestOutcome { result, inbound });
            }
            inbound.push(parse_inbound(&message)?);
        }
    }

    pub async fn next_inbound(&mut self) -> Result<WorkerInbound, WorkerError> {
        let message = self.read().await?;
        parse_inbound(&message)
    }

    pub async fn respond_callback(
        &mut self,
        id: &RequestId,
        result: Value,
    ) -> Result<(), WorkerError> {
        self.write(&json!({ "jsonrpc": "2.0", "id": id, "result": result }))
            .await
    }

    pub async fn deny_callback(
        &mut self,
        id: &RequestId,
        message: &str,
    ) -> Result<(), WorkerError> {
        self.respond_callback(
            id,
            json!({
                "decision": "deny",
                "message": message,
                "interrupt": false
            }),
        )
        .await
    }

    pub async fn shutdown(mut self) -> Result<(), WorkerError> {
        if self.child.try_wait()?.is_none() {
            let _ = self.request("worker/shutdown", json!({})).await;
        }
        if self.child.try_wait()?.is_none() {
            self.child.start_kill()?;
        }
        self.child.wait().await?;
        Ok(())
    }

    async fn write(&mut self, message: &Value) -> Result<(), WorkerError> {
        let mut frame = serde_json::to_vec(message)?;
        if frame.len() > MAX_FRAME_BYTES {
            return Err(WorkerError::FrameTooLarge);
        }
        frame.push(b'\n');
        self.stdin.write_all(&frame).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn read(&mut self) -> Result<Value, WorkerError> {
        let mut frame = match read_bounded_line(&mut self.stdout, MAX_FRAME_BYTES).await? {
            BoundedFrame::Closed => return Err(WorkerError::Closed),
            BoundedFrame::TooLarge => return Err(WorkerError::FrameTooLarge),
            BoundedFrame::Data(frame) => frame,
        };
        while matches!(frame.last(), Some(b'\n' | b'\r')) {
            frame.pop();
        }
        let value: Value = serde_json::from_slice(&frame)?;
        if value.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(WorkerError::UnexpectedFrame);
        }
        Ok(value)
    }
}

pub fn runtime_identity(initialize: &Value) -> Result<ProviderRuntime, WorkerError> {
    let diagnostics = initialize
        .get("diagnostics")
        .ok_or(WorkerError::Negotiation("worker diagnostics are missing"))?;
    if diagnostics["compatibility_profile"].as_str() != Some(CLAUDE_COMPATIBILITY_PROFILE) {
        return Err(WorkerError::Negotiation(
            "Claude compatibility profile mismatch",
        ));
    }
    if diagnostics["sdk"]["compatible"] != true {
        return Err(WorkerError::Negotiation("Claude SDK is incompatible"));
    }
    if diagnostics["claude_runtime"]["compatible"] != true {
        return Err(WorkerError::Negotiation("Claude runtime is incompatible"));
    }
    let sdk_version = diagnostics["sdk"]["version"]
        .as_str()
        .filter(|version| !version.is_empty())
        .ok_or(WorkerError::Negotiation("Claude SDK version is missing"))?;
    let runtime_version = diagnostics["claude_runtime"]["version"]
        .as_str()
        .filter(|version| !version.is_empty())
        .ok_or(WorkerError::Negotiation(
            "Claude runtime version is missing",
        ))?;
    let executable = diagnostics["claude_runtime"]["executable"]
        .as_str()
        .filter(|path| path.starts_with('/'))
        .map(str::to_owned);
    Ok(ProviderRuntime {
        compatibility_profile: CLAUDE_COMPATIBILITY_PROFILE.to_owned(),
        provider_version: runtime_version.to_owned(),
        adapter_version: Some(sdk_version.to_owned()),
        executable,
    })
}

impl Drop for ClaudeWorker {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

fn parse_inbound(message: &Value) -> Result<WorkerInbound, WorkerError> {
    let method = message
        .get("method")
        .and_then(Value::as_str)
        .ok_or(WorkerError::UnexpectedFrame)?
        .to_owned();
    let id = message
        .get("id")
        .cloned()
        .map(serde_json::from_value)
        .transpose()?;
    Ok(WorkerInbound {
        id,
        method,
        params: message.get("params").cloned().unwrap_or_else(|| json!({})),
    })
}

fn response_error(error: &Value) -> WorkerError {
    WorkerError::Response {
        code: error.get("code").and_then(Value::as_i64).unwrap_or(-32_000),
        message: error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown Claude worker error")
            .to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{CLAUDE_COMPATIBILITY_PROFILE, WorkerError, runtime_identity};

    #[test]
    fn profile_accepts_actual_sdk_and_bundled_runtime_versions() {
        let runtime = runtime_identity(&json!({
            "diagnostics": {
                "compatibility_profile": CLAUDE_COMPATIBILITY_PROFILE,
                "sdk": { "compatible": true, "version": "0.3.0" },
                "claude_runtime": {
                    "compatible": true,
                    "version": "2.2.0",
                    "executable": "/fixture/claude"
                }
            }
        }))
        .expect("compatible Claude runtime");
        assert_eq!(runtime.provider_version, "2.2.0");
        assert_eq!(runtime.adapter_version.as_deref(), Some("0.3.0"));
    }

    #[test]
    fn profile_rejects_an_incompatible_worker_report() {
        assert!(matches!(
            runtime_identity(&json!({
                "diagnostics": {
                    "compatibility_profile": CLAUDE_COMPATIBILITY_PROFILE,
                    "sdk": { "compatible": false, "version": "0.1.0" },
                    "claude_runtime": { "compatible": true, "version": "2.1.0" }
                }
            })),
            Err(WorkerError::Negotiation("Claude SDK is incompatible"))
        ));
    }
}
