//! Public broker protocol v1 types.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;
/// Co-shipped client/broker feature floor within public protocol v1.
pub const PROTOCOL_REVISION: u32 = 2;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(untagged)]
pub enum RequestId {
    Integer(i64),
    String(String),
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Codex,
    Claude,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceStrategy {
    Shared,
    Worktree,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOptions {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ManagedWorkspace {
    pub repository: String,
    pub task_id: String,
    pub branch: String,
    pub base_branch: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProviderRuntime {
    pub compatibility_profile: String,
    pub provider_version: String,
    pub adapter_version: Option<String>,
    pub executable: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    Starting,
    Idle,
    Running,
    WaitingInput,
    WaitingApproval,
    Completed,
    Interrupted,
    Failed,
    Disconnected,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityName {
    Streaming,
    MultiTurn,
    History,
    Resume,
    Fork,
    Interrupt,
    Steer,
    Approvals,
    Questions,
    Usage,
    FileChanges,
    Diff,
    Replay,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Capability {
    pub name: CapabilityName,
    pub available: bool,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentSummary {
    pub id: String,
    pub provider: Provider,
    pub provider_session_id: Option<String>,
    pub cwd: String,
    pub workspace_strategy: WorkspaceStrategy,
    pub worktree_path: Option<String>,
    pub managed_workspace: Option<ManagedWorkspace>,
    pub runtime: Option<ProviderRuntime>,
    #[serde(default)]
    pub provider_options: ProviderOptions,
    pub title: String,
    pub state: AgentState,
    pub active_turn_id: Option<String>,
    pub pending_approvals: u64,
    pub unread_events: u64,
    pub capabilities: Vec<Capability>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct EventEnvelope {
    pub protocol_version: u32,
    pub sequence: u64,
    pub timestamp: String,
    pub agent_id: String,
    pub provider: Provider,
    #[serde(rename = "type")]
    pub event_type: String,
    pub payload: Value,
    pub provider_event: Value,
}

impl EventEnvelope {
    #[must_use]
    pub fn new(
        timestamp: String,
        agent_id: String,
        provider: Provider,
        event_type: String,
        payload: Value,
        provider_event: Value,
    ) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            sequence: 0,
            timestamp,
            agent_id,
            provider,
            event_type,
            payload,
            provider_event,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RpcRequest {
    pub jsonrpc: String,
    pub id: RequestId,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RpcNotification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RpcResponse {
    pub jsonrpc: String,
    pub id: Option<RequestId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[cfg(test)]
mod tests {
    use super::{AgentSummary, EventEnvelope, RpcRequest, RpcResponse};

    #[test]
    fn committed_public_fixtures_deserialize() {
        let event =
            include_str!("../../../protocol/broker/v1/fixtures/agent-event.notification.json");
        let state = include_str!("../../../protocol/broker/v1/fixtures/state.notification.json");
        let initialize =
            include_str!("../../../protocol/broker/v1/fixtures/initialize.request.json");
        let parse_error =
            include_str!("../../../protocol/broker/v1/fixtures/parse-error.response.json");

        let event_value: serde_json::Value = serde_json::from_str(event).expect("event JSON");
        let event: EventEnvelope =
            serde_json::from_value(event_value["params"].clone()).expect("event envelope");
        assert_eq!(event.sequence, 42);

        let state_value: serde_json::Value = serde_json::from_str(state).expect("state JSON");
        let agents: Vec<AgentSummary> =
            serde_json::from_value(state_value["params"]["agents"].clone())
                .expect("agent summaries");
        assert_eq!(agents.len(), 1);

        let request: RpcRequest = serde_json::from_str(initialize).expect("initialize request");
        assert_eq!(request.method, "initialize");

        let response: RpcResponse = serde_json::from_str(parse_error).expect("error response");
        assert!(response.id.is_none());
        assert_eq!(response.error.expect("error object").code, -32_700);
    }
}
