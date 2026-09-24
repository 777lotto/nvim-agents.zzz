//! Public JSON-RPC broker core and embedded stdio transport.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::io::{AsyncBufRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task::{JoinError, JoinHandle};
use uuid::Uuid;

use crate::BROKER_VERSION;
use crate::codex::{CODEX_COMPATIBILITY_PROFILE, CODEX_SCHEMA_BASELINE_VERSION, CommandSpec};
use crate::framing::{BoundedFrame, read_bounded_line};
use crate::protocol::{
    AgentState, AgentSummary, Capability, CapabilityName, EventEnvelope, ManagedWorkspace,
    PROTOCOL_REVISION, PROTOCOL_VERSION, Provider, ProviderOptions, RequestId, WorkspaceStrategy,
};
use crate::registry::RegistryStore;
use crate::replay::{ReplayBuffer, ReplayResult};
use crate::runtime::{
    AgentCommand, AgentSpawn, RuntimeConfig, RuntimeEvent, SessionLaunch, delete_provider_session,
    discover_models, discover_sessions, spawn_agent,
};
use crate::status::StatusStore;
use crate::worker::{
    CLAUDE_COMPATIBILITY_PROFILE, TESTED_CLAUDE_CODE_VERSION, TESTED_CLAUDE_SDK_VERSION,
    WorkerCommandSpec,
};
use crate::workspace::{WorkspaceCommandSpec, WorkspaceLifecycle};

const MAX_PUBLIC_FRAME_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_REPLAY_CAPACITY: usize = 2_000;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const DIFF_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CONTEXT_BYTES: usize = 512 * 1024;
const MAX_CONTEXT_ITEMS: usize = 256;
const MAX_DIFF_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct EmbeddedConfig {
    runtime: RuntimeConfig,
    workspace: Option<WorkspaceCommandSpec>,
    allow_shared_workspaces: bool,
    replay_capacity: usize,
}

impl Default for EmbeddedConfig {
    fn default() -> Self {
        Self {
            runtime: RuntimeConfig::default(),
            workspace: Some(WorkspaceCommandSpec::default()),
            allow_shared_workspaces: true,
            replay_capacity: DEFAULT_REPLAY_CAPACITY,
        }
    }
}

impl EmbeddedConfig {
    #[must_use]
    pub fn with_codex_program(mut self, program: impl Into<String>) -> Self {
        self.runtime.codex.program = program.into();
        self
    }

    #[must_use]
    pub fn with_claude_python(mut self, python: impl Into<String>) -> Self {
        self.runtime.claude = WorkerCommandSpec {
            program: python.into(),
            args: vec![
                "-B".to_owned(),
                "-I".to_owned(),
                "-m".to_owned(),
                "agent_manager_claude_worker".to_owned(),
            ],
        };
        self
    }

    #[must_use]
    pub fn with_workspace_lifecycle(mut self, program: impl Into<String>) -> Self {
        self.workspace = Some(WorkspaceCommandSpec {
            program: program.into(),
        });
        self
    }

    #[must_use]
    pub fn without_workspace_lifecycle(mut self) -> Self {
        self.workspace = None;
        self
    }

    #[must_use]
    pub const fn with_shared_workspaces(mut self, allowed: bool) -> Self {
        self.allow_shared_workspaces = allowed;
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_provider_commands(mut self, codex: CommandSpec, claude: WorkerCommandSpec) -> Self {
        self.runtime.codex = codex;
        self.runtime.codex_thread_locks = None;
        self.runtime.claude = claude;
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_codex_thread_locks(mut self, directory: impl Into<PathBuf>) -> Self {
        self.runtime.codex_thread_locks = Some(directory.into());
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_callback_timeout(mut self, timeout: Duration) -> Self {
        self.runtime.callback_timeout = timeout;
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_replay_capacity(mut self, capacity: usize) -> Self {
        assert!(capacity > 0, "replay capacity must be positive");
        self.replay_capacity = capacity;
        self
    }
}

#[derive(Debug, Error)]
pub enum EmbeddedError {
    #[error("embedded broker I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("embedded broker task failed: {0}")]
    Join(#[from] JoinError),
    #[error("embedded broker serialization failed: {0}")]
    Json(#[from] serde_json::Error),
}

pub async fn serve<R, W>(reader: R, writer: W, config: EmbeddedConfig) -> Result<(), EmbeddedError>
where
    R: AsyncBufRead + Send + Unpin + 'static,
    W: AsyncWrite + Send + Unpin + 'static,
{
    let (input_tx, input_rx) = mpsc::unbounded_channel();
    let generation = 1;
    let (output_tx, output_rx) = mpsc::unbounded_channel();
    let _ = input_tx.send(ClientInput::Connected {
        generation,
        output: output_tx,
    });
    let input_handle = tokio::spawn(read_client(reader, input_tx, generation));
    let output_handle = tokio::spawn(write_client(writer, output_rx));
    let (runtime_tx, runtime_rx) = mpsc::unbounded_channel();

    let mut broker = Broker::new(
        config,
        BrokerMode::Embedded,
        runtime_tx,
        None,
        Vec::new(),
        None,
    );
    let broker_result = broker.run(input_rx, runtime_rx).await;
    broker.shutdown_agents().await;
    drop(broker.output.take());

    input_handle.abort();
    let _ = input_handle.await;
    output_handle.await??;
    broker_result
}

#[derive(Debug)]
pub(crate) enum ClientInput {
    Connected {
        generation: u64,
        output: mpsc::UnboundedSender<Value>,
    },
    Frame {
        generation: u64,
        value: Value,
    },
    ParseError {
        generation: u64,
    },
    FrameTooLarge {
        generation: u64,
    },
    Io {
        generation: u64,
        error: io::Error,
    },
    Closed {
        generation: u64,
    },
}

pub(crate) async fn read_client<R>(
    mut reader: R,
    input: mpsc::UnboundedSender<ClientInput>,
    generation: u64,
) where
    R: AsyncBufRead + Unpin,
{
    loop {
        let frame = match read_bounded_line(&mut reader, MAX_PUBLIC_FRAME_BYTES).await {
            Ok(frame) => frame,
            Err(error) => {
                let _ = input.send(ClientInput::Io { generation, error });
                return;
            }
        };
        match frame {
            BoundedFrame::Closed => {
                let _ = input.send(ClientInput::Closed { generation });
                return;
            }
            BoundedFrame::TooLarge => {
                let _ = input.send(ClientInput::FrameTooLarge { generation });
                return;
            }
            BoundedFrame::Data(mut data) => {
                while matches!(data.last(), Some(b'\n' | b'\r')) {
                    data.pop();
                }
                match serde_json::from_slice(&data) {
                    Ok(value) => {
                        if input
                            .send(ClientInput::Frame { generation, value })
                            .is_err()
                        {
                            return;
                        }
                    }
                    Err(_) => {
                        if input.send(ClientInput::ParseError { generation }).is_err() {
                            return;
                        }
                    }
                }
            }
        }
    }
}

pub(crate) async fn write_client<W>(
    mut writer: W,
    mut output: mpsc::UnboundedReceiver<Value>,
) -> Result<(), EmbeddedError>
where
    W: AsyncWrite + Unpin,
{
    while let Some(message) = output.recv().await {
        let mut frame = serde_json::to_vec(&message)?;
        frame.push(b'\n');
        writer.write_all(&frame).await?;
        writer.flush().await?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectionPhase {
    AwaitInitialize,
    AwaitInitialized,
    Ready,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BrokerMode {
    Embedded,
    Durable,
}

impl BrokerMode {
    const fn name(self) -> &'static str {
        match self {
            Self::Embedded => "embedded",
            Self::Durable => "durable",
        }
    }
}

struct PendingRuntimeRequest {
    generation: u64,
    public_id: RequestId,
}

struct QueuedPrompt {
    text: String,
    attachments: Vec<Value>,
    provider_options: ProviderOptions,
}

struct ManagedAgent {
    summary: AgentSummary,
    workspace_identity: PathBuf,
    commands: mpsc::Sender<AgentCommand>,
    task: Option<JoinHandle<()>>,
    pending_contexts: Vec<Value>,
    queued_prompts: VecDeque<QueuedPrompt>,
    pending_questions: u64,
    has_prompted: bool,
    title_from_prompt: bool,
}

struct ResolvedWorkspace {
    cwd: PathBuf,
    strategy: WorkspaceStrategy,
    worktree_path: Option<String>,
    managed: Option<ManagedWorkspace>,
}

pub(crate) struct Broker {
    phase: ConnectionPhase,
    mode: BrokerMode,
    connection_generation: u64,
    reconnect_cursor: u64,
    config: EmbeddedConfig,
    agents: HashMap<String, ManagedAgent>,
    agent_order: Vec<String>,
    replay: ReplayBuffer,
    output: Option<mpsc::UnboundedSender<Value>>,
    runtime: mpsc::UnboundedSender<RuntimeEvent>,
    next_runtime_request: u64,
    pending_runtime_requests: HashMap<RequestId, PendingRuntimeRequest>,
    queued_runtime_requests: HashSet<RequestId>,
    registry: Option<RegistryStore>,
    status: Option<StatusStore>,
}

impl Broker {
    pub(crate) fn new(
        config: EmbeddedConfig,
        mode: BrokerMode,
        runtime: mpsc::UnboundedSender<RuntimeEvent>,
        registry: Option<RegistryStore>,
        restored_agents: Vec<AgentSummary>,
        status: Option<StatusStore>,
    ) -> Self {
        let mut agents = HashMap::new();
        let mut agent_order = Vec::new();
        for mut summary in restored_agents {
            summary.capabilities = capabilities(summary.provider);
            let (commands, commands_rx) = mpsc::channel(1);
            drop(commands_rx);
            agent_order.push(summary.id.clone());
            agents.insert(
                summary.id.clone(),
                ManagedAgent {
                    workspace_identity: checkout_identity(
                        summary.workspace_strategy,
                        Path::new(&summary.cwd),
                    ),
                    summary,
                    commands,
                    task: None,
                    pending_contexts: Vec::new(),
                    queued_prompts: VecDeque::new(),
                    pending_questions: 0,
                    has_prompted: true,
                    title_from_prompt: false,
                },
            );
        }
        Self {
            phase: ConnectionPhase::AwaitInitialize,
            mode,
            connection_generation: 0,
            reconnect_cursor: 0,
            replay: ReplayBuffer::new(config.replay_capacity),
            config,
            agents,
            agent_order,
            output: None,
            runtime,
            next_runtime_request: 1,
            pending_runtime_requests: HashMap::new(),
            queued_runtime_requests: HashSet::new(),
            registry,
            status,
        }
    }

    pub(crate) async fn run(
        &mut self,
        mut input: mpsc::UnboundedReceiver<ClientInput>,
        mut runtime: mpsc::UnboundedReceiver<RuntimeEvent>,
    ) -> Result<(), EmbeddedError> {
        loop {
            tokio::select! {
                client = input.recv() => {
                    let Some(client) = client else {
                        return Ok(());
                    };
                    match client {
                        ClientInput::Connected { generation, output } => {
                            self.connect(generation, output);
                        }
                        ClientInput::Frame { generation, value } => {
                            if generation != self.connection_generation {
                                continue;
                            }
                            if self.handle_client_frame(value).await? {
                                return Ok(());
                            }
                        }
                        ClientInput::ParseError { generation } => {
                            if generation == self.connection_generation {
                                self.send(error_response(None, -32_700, "Parse error", None));
                            }
                        }
                        ClientInput::FrameTooLarge { generation } => {
                            if generation != self.connection_generation {
                                continue;
                            }
                            self.send(error_response(
                                None,
                                -32_600,
                                "Invalid Request",
                                Some(json!({ "reason": "frame_too_large" })),
                            ));
                            if self.mode == BrokerMode::Embedded {
                                return Ok(());
                            }
                            self.disconnect(generation);
                        }
                        ClientInput::Io { generation, error } => {
                            if generation != self.connection_generation {
                                continue;
                            }
                            if self.mode == BrokerMode::Embedded {
                                return Err(EmbeddedError::Io(error));
                            }
                            self.disconnect(generation);
                        }
                        ClientInput::Closed { generation } => {
                            if generation != self.connection_generation {
                                continue;
                            }
                            if self.mode == BrokerMode::Embedded {
                                return Ok(());
                            }
                            self.disconnect(generation);
                        }
                    }
                }
                provider = runtime.recv() => {
                    let Some(provider) = provider else {
                        return Ok(());
                    };
                    self.handle_runtime_event(provider);
                }
            }
        }
    }

    fn connect(&mut self, generation: u64, output: mpsc::UnboundedSender<Value>) {
        if generation <= self.connection_generation {
            return;
        }
        self.connection_generation = generation;
        self.phase = ConnectionPhase::AwaitInitialize;
        self.reconnect_cursor = 0;
        self.output = Some(output);
    }

    fn disconnect(&mut self, generation: u64) {
        if generation != self.connection_generation {
            return;
        }
        self.output = None;
        self.phase = ConnectionPhase::AwaitInitialize;
        self.reconnect_cursor = 0;
        self.pending_runtime_requests
            .retain(|_, pending| pending.generation != generation);
        for agent in self.agents.values() {
            queue_client_disconnect(&agent.commands);
        }
    }

    async fn handle_client_frame(&mut self, frame: Value) -> Result<bool, EmbeddedError> {
        let Some(object) = frame.as_object() else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        }
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        if !params.is_object() {
            let response_id = object
                .get("id")
                .cloned()
                .and_then(|id| serde_json::from_value(id).ok());
            self.send(error_response(response_id, -32_602, "Invalid params", None));
            return Ok(false);
        }

        let Some(raw_id) = object.get("id") else {
            self.handle_notification(method, &params);
            return Ok(false);
        };
        let Ok(request_id) = serde_json::from_value::<RequestId>(raw_id.clone()) else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        self.handle_request(request_id, method, params).await
    }

    fn handle_notification(&mut self, method: &str, params: &Value) {
        if self.phase == ConnectionPhase::AwaitInitialized
            && method == "initialized"
            && params.as_object().is_some_and(serde_json::Map::is_empty)
        {
            self.phase = ConnectionPhase::Ready;
            if self.mode == BrokerMode::Durable
                && let ReplayResult::Events(events) =
                    self.replay.replay_after(self.reconnect_cursor)
            {
                for event in events {
                    self.send(json!({
                        "jsonrpc": "2.0",
                        "method": "agent/event",
                        "params": event,
                    }));
                }
            }
            self.notify_state();
        }
    }

    async fn handle_request(
        &mut self,
        request_id: RequestId,
        method: &str,
        params: Value,
    ) -> Result<bool, EmbeddedError> {
        if self.phase == ConnectionPhase::AwaitInitialize {
            if method != "initialize" {
                self.send(error_response(
                    Some(request_id),
                    -32_002,
                    "Broker is not initialized",
                    None,
                ));
                return Ok(false);
            }
            return Ok(self.initialize(request_id, params));
        }
        if self.phase == ConnectionPhase::AwaitInitialized {
            self.send(error_response(
                Some(request_id),
                -32_003,
                "Broker is waiting for initialized",
                None,
            ));
            return Ok(false);
        }

        match method {
            "initialize" => self.send(error_response(
                Some(request_id),
                -32_004,
                "Broker is already initialized",
                None,
            )),
            "agent/list" => self.send(success_response(
                request_id,
                json!({ "agents": self.summaries() }),
            )),
            "workspace/list" => self.list_workspaces(request_id).await,
            "workspace/handoff" => self.handoff_workspace(request_id, params).await,
            "workspace/diff" => self.workspace_diff(request_id, params).await,
            "provider/model/list" => self.provider_models(request_id, params).await,
            "provider/session/list" => self.provider_sessions(request_id, params).await,
            "provider/session/delete" => self.delete_session(request_id, params).await,
            "agent/start" => {
                self.start_agent(request_id, params, SessionLaunch::Start)
                    .await;
            }
            "agent/attach" => self.attach_agent(request_id, params),
            "agent/history" => self.history(request_id, params).await,
            "agent/prompt" => {
                self.send_agent_input(request_id, params, InputKind::Prompt)
                    .await;
            }
            "agent/steer" => {
                self.send_agent_input(request_id, params, InputKind::Steer)
                    .await;
            }
            "agent/interrupt" => self.interrupt_agent(request_id, params).await,
            "agent/resume" => self.resume_agent(request_id, params).await,
            "agent/fork" => self.fork_agent(request_id, params).await,
            "agent/archive" => self.archive_agent(request_id, params).await,
            "agent/approval/respond" => self.respond_approval(request_id, params).await,
            "agent/question/respond" => self.respond_question(request_id, params).await,
            "agent/context/add" => self.add_context(request_id, params),
            "agent/diff" => self.diff(request_id, params).await,
            "agent/replay" => self.replay(request_id, params),
            "broker/shutdown" => {
                if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                    self.send(invalid_params(request_id, "params must be empty"));
                    return Ok(false);
                }
                if self.mode == BrokerMode::Durable {
                    self.send(error_response(
                        Some(request_id),
                        -32_010,
                        "Durable broker shutdown is owned by the lifecycle manager",
                        None,
                    ));
                    return Ok(false);
                }
                self.send(success_response(request_id, json!({ "shutdown": true })));
                return Ok(true);
            }
            _ => self.send(error_response(
                Some(request_id),
                -32_601,
                "Method not found",
                None,
            )),
        }
        Ok(false)
    }

    fn initialize(&mut self, request_id: RequestId, params: Value) -> bool {
        let Ok(parsed) = serde_json::from_value::<InitializeParams>(params) else {
            self.send(invalid_params(request_id, "invalid initialize parameters"));
            return false;
        };
        if parsed.protocol_version != PROTOCOL_VERSION
            || parsed.client.name.is_empty()
            || parsed.client.version.is_empty()
        {
            self.send(invalid_params(
                request_id,
                "unsupported protocol or empty client identity",
            ));
            return false;
        }
        self.phase = ConnectionPhase::AwaitInitialized;
        self.reconnect_cursor = parsed.last_sequence.unwrap_or(0);
        let (oldest, latest) = self
            .replay
            .bounds()
            .map_or((None, None), |(oldest, latest)| {
                (Some(oldest), Some(latest))
            });
        let resync_required = self.mode == BrokerMode::Durable
            && matches!(
                self.replay.replay_after(self.reconnect_cursor),
                ReplayResult::ResyncRequired { .. }
            );
        if resync_required {
            self.reconnect_cursor = latest.unwrap_or(self.reconnect_cursor);
        }
        self.send(success_response(
            request_id,
            json!({
                "protocol_version": PROTOCOL_VERSION,
                "protocol_revision": PROTOCOL_REVISION,
                "broker_version": BROKER_VERSION,
                "mode": self.mode.name(),
                "providers": {
                    "codex": {
                        "compatibility_profile": CODEX_COMPATIBILITY_PROFILE,
                        "schema_baseline_version": CODEX_SCHEMA_BASELINE_VERSION,
                    },
                    "claude": {
                        "compatibility_profile": CLAUDE_COMPATIBILITY_PROFILE,
                        "tested_agent_sdk_version": TESTED_CLAUDE_SDK_VERSION,
                        "tested_claude_code_version": TESTED_CLAUDE_CODE_VERSION,
                    }
                },
                "replay": {
                    "capacity": self.config.replay_capacity,
                    "oldest": oldest,
                    "latest": latest,
                    "resync_required": resync_required,
                },
                "registry": {
                    "path": self.registry.as_ref().map(RegistryStore::path),
                    "metadata_only": true,
                },
                "workspaces": {
                    "managed_tasks": self.config.workspace.is_some(),
                    "shared_starts": self.config.allow_shared_workspaces,
                    "authority": "external_lifecycle",
                    "destructive_controls": false,
                },
                "provider_sessions": {
                    "delete": true,
                    "worktree_preserved": true,
                },
            }),
        ));
        false
    }

    async fn list_workspaces(&self, request_id: RequestId) {
        let Some(command) = self.config.workspace.clone() else {
            self.send(error_response(
                Some(request_id),
                -32_030,
                "Managed workspace lifecycle is disabled",
                None,
            ));
            return;
        };
        match WorkspaceLifecycle::new(command).inventory().await {
            Ok(inventory) => self.send(success_response(request_id, json!(inventory))),
            Err(error) => self.send(error_response(
                Some(request_id),
                -32_030,
                &error.to_string(),
                None,
            )),
        }
    }

    async fn handoff_workspace(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ManagedWorkspaceParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid managed workspace parameters",
            ));
            return;
        };
        if self.agents.values().any(|agent| {
            agent.task.is_some()
                && agent
                    .summary
                    .managed_workspace
                    .as_ref()
                    .is_some_and(|workspace| {
                        workspace.repository == parsed.repository
                            && workspace.task_id == parsed.task_id
                    })
        }) {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "A live agent still owns this managed task",
                None,
            ));
            return;
        }
        let Some(command) = self.config.workspace.clone() else {
            self.send(error_response(
                Some(request_id),
                -32_030,
                "Managed workspace lifecycle is disabled",
                None,
            ));
            return;
        };
        match WorkspaceLifecycle::new(command)
            .handoff(&parsed.repository, &parsed.task_id)
            .await
        {
            Ok(()) => self.send(success_response(
                request_id,
                json!({
                    "handed_off": true,
                    "repository": parsed.repository,
                    "task_id": parsed.task_id,
                }),
            )),
            Err(error) => self.send(error_response(
                Some(request_id),
                -32_030,
                &error.to_string(),
                None,
            )),
        }
    }

    async fn provider_sessions(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ProviderSessionListParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid provider session list parameters",
            ));
            return;
        };
        let cwd = match parsed.cwd.as_deref() {
            Some(cwd) => match canonical_directory(cwd) {
                Ok(cwd) => Some(cwd),
                Err(message) => {
                    self.send(invalid_params(request_id, message));
                    return;
                }
            },
            None => None,
        };
        let limit = parsed.limit.unwrap_or(50).clamp(1, 1_000);
        match discover_sessions(
            parsed.provider,
            cwd.as_deref(),
            parsed.cursor.as_deref(),
            limit,
            parsed.active_only.unwrap_or(false),
            &self.config.runtime,
        )
        .await
        {
            Ok(result) => self.send(success_response(request_id, result)),
            Err(message) => self.send(error_response(Some(request_id), -32_020, message, None)),
        }
    }

    async fn provider_models(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ProviderModelListParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid provider model list parameters",
            ));
            return;
        };
        match discover_models(parsed.provider, &self.config.runtime).await {
            Ok(result) => self.send(success_response(request_id, result)),
            Err(message) => self.send(error_response(Some(request_id), -32_020, message, None)),
        }
    }

    #[allow(clippy::too_many_lines)]
    async fn delete_session(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ProviderSessionDeleteParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid provider session delete parameters",
            ));
            return;
        };
        if parsed.provider_session_id.is_empty() || parsed.provider_session_id.len() > 1_024 {
            self.send(invalid_params(
                request_id,
                "invalid provider session identity",
            ));
            return;
        }
        let cwd = match canonical_directory(&parsed.cwd) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let matching_agent_ids = self
            .agent_order
            .iter()
            .filter(|agent_id| {
                self.agents.get(*agent_id).is_some_and(|agent| {
                    agent.summary.provider == parsed.provider
                        && agent.summary.provider_session_id.as_deref()
                            == Some(parsed.provider_session_id.as_str())
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        if matching_agent_ids.iter().any(|agent_id| {
            self.agents.get(agent_id).is_some_and(|agent| {
                matches!(
                    agent.summary.state,
                    AgentState::Starting
                        | AgentState::Running
                        | AgentState::WaitingInput
                        | AgentState::WaitingApproval
                ) || agent.summary.pending_approvals > 0
                    || agent.pending_questions > 0
            })
        }) {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "An agent with active work or a pending human request cannot be deleted",
                None,
            ));
            return;
        }
        let mut managed_workspaces = Vec::<ManagedWorkspace>::new();
        for agent_id in &matching_agent_ids {
            if let Some(workspace) = self
                .agents
                .get(agent_id)
                .and_then(|agent| agent.summary.managed_workspace.clone())
                && !managed_workspaces.iter().any(|candidate| {
                    candidate.repository == workspace.repository
                        && candidate.task_id == workspace.task_id
                })
            {
                managed_workspaces.push(workspace);
            }
        }
        let workspace_command = if managed_workspaces.is_empty() {
            None
        } else {
            let Some(command) = self.config.workspace.clone() else {
                self.send(error_response(
                    Some(request_id),
                    -32_030,
                    "Managed workspace lifecycle is disabled",
                    None,
                ));
                return;
            };
            Some(command)
        };

        for agent_id in &matching_agent_ids {
            if self
                .agents
                .get(agent_id)
                .is_some_and(|agent| agent.task.is_some())
            {
                self.retire_agent(agent_id).await;
            }
        }
        if let Some(command) = workspace_command {
            let lifecycle = WorkspaceLifecycle::new(command);
            for workspace in &managed_workspaces {
                if let Err(error) = lifecycle
                    .handoff(&workspace.repository, &workspace.task_id)
                    .await
                {
                    self.send(error_response(
                        Some(request_id),
                        -32_030,
                        &error.to_string(),
                        None,
                    ));
                    return;
                }
            }
        }
        if let Err(message) = delete_provider_session(
            parsed.provider,
            &parsed.provider_session_id,
            &cwd,
            &self.config.runtime,
        )
        .await
        {
            self.send(error_response(Some(request_id), -32_020, message, None));
            return;
        }
        for agent_id in &matching_agent_ids {
            self.agents.remove(agent_id);
        }
        self.agent_order
            .retain(|agent_id| !matching_agent_ids.contains(agent_id));
        self.send(success_response(
            request_id,
            json!({
                "deleted": true,
                "provider": parsed.provider,
                "provider_session_id": parsed.provider_session_id,
                "workspace_handed_off": !managed_workspaces.is_empty(),
                "worktree_preserved": true,
            }),
        ));
        self.notify_state();
    }

    async fn start_agent(&mut self, request_id: RequestId, params: Value, launch: SessionLaunch) {
        let Ok(parsed) = serde_json::from_value::<StartParams>(params) else {
            self.send(invalid_params(request_id, "invalid start parameters"));
            return;
        };
        let provider_options = parsed.provider_options.unwrap_or_default();
        if let Err(message) = validate_provider_options(parsed.provider, &provider_options) {
            self.send(invalid_params(request_id, message));
            return;
        }
        let Some(workspace) = self
            .resolve_launch_workspace(
                &request_id,
                parsed.cwd.as_deref(),
                parsed.workspace_strategy,
                parsed.worktree_path.as_deref(),
                parsed.managed_workspace.as_ref(),
            )
            .await
        else {
            return;
        };

        let _ = self.launch_agent(
            request_id,
            parsed.provider,
            workspace,
            provider_options,
            launch,
        );
    }

    async fn resolve_launch_workspace(
        &self,
        request_id: &RequestId,
        raw_cwd: Option<&str>,
        strategy: Option<WorkspaceStrategy>,
        worktree_path: Option<&str>,
        managed: Option<&ManagedWorkspaceParams>,
    ) -> Option<ResolvedWorkspace> {
        if let Some(managed) = managed {
            if raw_cwd.is_some() || strategy.is_some() || worktree_path.is_some() {
                self.send(invalid_params(
                    request_id.clone(),
                    "managed_workspace cannot be combined with explicit workspace fields",
                ));
                return None;
            }
            return self.resolve_managed_workspace(request_id, managed).await;
        }
        self.resolve_explicit_workspace(request_id, raw_cwd, strategy, worktree_path)
    }

    async fn resolve_managed_workspace(
        &self,
        request_id: &RequestId,
        managed: &ManagedWorkspaceParams,
    ) -> Option<ResolvedWorkspace> {
        if self.mode == BrokerMode::Embedded
            && self.agents.values().any(|agent| agent.task.is_some())
        {
            self.send(error_response(
                Some(request_id.clone()),
                -32_011,
                "M2 embedded mode supports one live agent",
                None,
            ));
            return None;
        }
        if self.agents.values().any(|agent| {
            agent.task.is_some()
                && agent
                    .summary
                    .managed_workspace
                    .as_ref()
                    .is_some_and(|workspace| {
                        workspace.repository == managed.repository
                            && workspace.task_id == managed.task_id
                    })
        }) {
            self.send(error_response(
                Some(request_id.clone()),
                -32_012,
                "A writable agent already owns this managed task",
                None,
            ));
            return None;
        }
        let Some(command) = self.config.workspace.clone() else {
            self.send(error_response(
                Some(request_id.clone()),
                -32_030,
                "Managed workspace lifecycle is disabled",
                None,
            ));
            return None;
        };
        let (path, metadata) = match WorkspaceLifecycle::new(command)
            .claim(&managed.repository, &managed.task_id, managed.resume)
            .await
        {
            Ok(claimed) => claimed,
            Err(error) => {
                self.send(error_response(
                    Some(request_id.clone()),
                    -32_030,
                    &error.to_string(),
                    None,
                ));
                return None;
            }
        };
        let cwd = match canonical_directory(&path) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id.clone(), message));
                return None;
            }
        };
        let worktree_path = match validate_workspace(
            WorkspaceStrategy::Worktree,
            Some(&path),
            &cwd,
            BrokerMode::Durable,
        ) {
            Ok(path) => path,
            Err(message) => {
                self.send(invalid_params(request_id.clone(), message));
                return None;
            }
        };
        Some(ResolvedWorkspace {
            cwd,
            strategy: WorkspaceStrategy::Worktree,
            worktree_path,
            managed: Some(metadata),
        })
    }

    fn resolve_explicit_workspace(
        &self,
        request_id: &RequestId,
        raw_cwd: Option<&str>,
        strategy: Option<WorkspaceStrategy>,
        worktree_path: Option<&str>,
    ) -> Option<ResolvedWorkspace> {
        let (Some(raw_cwd), Some(strategy)) = (raw_cwd, strategy) else {
            self.send(invalid_params(
                request_id.clone(),
                "explicit launches require cwd and workspace_strategy",
            ));
            return None;
        };
        let cwd = match canonical_directory(raw_cwd) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id.clone(), message));
                return None;
            }
        };
        let worktree_path = match validate_workspace(strategy, worktree_path, &cwd, self.mode) {
            Ok(path) => path,
            Err(message) => {
                self.send(invalid_params(request_id.clone(), message));
                return None;
            }
        };
        Some(ResolvedWorkspace {
            cwd,
            strategy,
            worktree_path,
            managed: None,
        })
    }

    fn workspace_launch_allowed(
        &self,
        request_id: &RequestId,
        provider: Provider,
        workspace: &ResolvedWorkspace,
        launch: &SessionLaunch,
    ) -> bool {
        if workspace.strategy == WorkspaceStrategy::Shared
            && !self.config.allow_shared_workspaces
            && !is_codex_directory_resume(provider, launch, &workspace.cwd)
        {
            self.send(error_response(
                Some(request_id.clone()),
                -32_031,
                "Shared-checkout starts are disabled by broker policy",
                None,
            ));
            return false;
        }
        true
    }

    fn launch_agent(
        &mut self,
        request_id: RequestId,
        provider: Provider,
        workspace: ResolvedWorkspace,
        provider_options: ProviderOptions,
        launch: SessionLaunch,
    ) -> Option<String> {
        if !self.workspace_launch_allowed(&request_id, provider, &workspace, &launch) {
            return None;
        }
        let ResolvedWorkspace {
            cwd,
            strategy: workspace_strategy,
            worktree_path,
            managed: managed_workspace,
        } = workspace;
        if self.mode == BrokerMode::Embedded
            && self.agents.values().any(|agent| agent.task.is_some())
        {
            self.send(error_response(
                Some(request_id),
                -32_011,
                "M2 embedded mode supports one live agent",
                None,
            ));
            return None;
        }
        let workspace_identity = checkout_identity(workspace_strategy, &cwd);
        if self.agents.values().any(|agent| {
            agent.task.is_some()
                && !matches!(
                    agent.summary.state,
                    AgentState::Disconnected | AgentState::Failed
                )
                && agent.workspace_identity == workspace_identity
        }) {
            self.send(error_response(
                Some(request_id),
                -32_012,
                "A writable agent already owns this checkout; select an isolated worktree",
                Some(json!({
                    "reason": "shared_checkout_writer_conflict",
                    "cwd": cwd,
                    "workspace_strategy": workspace_strategy,
                })),
            ));
            return None;
        }
        let agent_id = Uuid::new_v4().to_string();
        let now = timestamp();
        let title = directory_title(&cwd, provider);
        let has_prompted = !matches!(&launch, SessionLaunch::Start);
        let summary = AgentSummary {
            id: agent_id.clone(),
            provider,
            provider_session_id: None,
            cwd: cwd.to_string_lossy().into_owned(),
            workspace_strategy,
            worktree_path,
            managed_workspace,
            runtime: None,
            provider_options: provider_options.clone(),
            title,
            state: AgentState::Starting,
            active_turn_id: None,
            pending_approvals: 0,
            unread_events: 0,
            capabilities: capabilities(provider),
            created_at: now.clone(),
            updated_at: now,
        };
        let runtime_request_id = self.runtime_request(request_id);
        let (commands, task) = spawn_agent(
            AgentSpawn {
                provider,
                agent_id: agent_id.clone(),
                cwd,
                start_request_id: runtime_request_id,
                launch,
                provider_options,
            },
            self.config.runtime.clone(),
            self.runtime.clone(),
        );
        self.agent_order.push(agent_id.clone());
        self.agents.insert(
            agent_id.clone(),
            ManagedAgent {
                summary,
                workspace_identity,
                commands,
                task: Some(task),
                pending_contexts: Vec::new(),
                queued_prompts: VecDeque::new(),
                pending_questions: 0,
                has_prompted,
                title_from_prompt: false,
            },
        );
        self.notify_state();
        Some(agent_id)
    }

    fn attach_agent(&self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        self.send(success_response(
            request_id,
            json!({ "agent": agent.summary }),
        ));
    }

    async fn history(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<HistoryParams>(params) else {
            self.send(invalid_params(request_id, "invalid history parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if agent.task.is_none() {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent is not live; resume the provider session before reading history",
                None,
            ));
            return;
        }
        let runtime_request_id = self.runtime_request(request_id.clone());
        let command_failed = self
            .agents
            .get_mut(&parsed.agent_id)
            .expect("validated agent must remain present")
            .commands
            .send(AgentCommand::History {
                request_id: runtime_request_id.clone(),
                cursor: parsed.cursor,
                limit: parsed.limit,
            })
            .await
            .is_err();
        if command_failed {
            self.pending_runtime_requests.remove(&runtime_request_id);
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    async fn resume_agent(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ResumeParams>(params) else {
            self.send(invalid_params(request_id, "invalid resume parameters"));
            return;
        };
        if parsed.provider_session_id.is_empty() {
            self.send(invalid_params(
                request_id,
                "provider session id must not be empty",
            ));
            return;
        }
        let provider_options = parsed.provider_options.unwrap_or_default();
        if let Err(message) = validate_provider_options(parsed.provider, &provider_options) {
            self.send(invalid_params(request_id, message));
            return;
        }
        let Some(workspace) = self
            .resolve_launch_workspace(
                &request_id,
                parsed.cwd.as_deref(),
                parsed.workspace_strategy,
                parsed.worktree_path.as_deref(),
                parsed.managed_workspace.as_ref(),
            )
            .await
        else {
            return;
        };
        let session_id = parsed.provider_session_id;
        let _ = self.launch_agent(
            request_id,
            parsed.provider,
            workspace,
            provider_options,
            SessionLaunch::Resume(session_id),
        );
    }

    async fn fork_agent(&mut self, request_id: RequestId, params: Value) {
        let Some(source_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(source) = self.agents.get(&source_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if !matches!(
            source.summary.state,
            AgentState::Idle | AgentState::Completed | AgentState::Interrupted
        ) || source.summary.pending_approvals > 0
            || source.pending_questions > 0
        {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent must be idle with no pending human request before it can be forked",
                None,
            ));
            return;
        }
        let Some(provider_session_id) = source.summary.provider_session_id.clone() else {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent has no provider session identity to fork",
                None,
            ));
            return;
        };
        let provider = source.summary.provider;
        let cwd = PathBuf::from(&source.summary.cwd);
        let strategy = source.summary.workspace_strategy;
        let worktree_path = source.summary.worktree_path.clone();
        let managed_workspace = source.summary.managed_workspace.clone();
        let pending_contexts = source.pending_contexts.clone();
        let provider_options = source.summary.provider_options.clone();
        self.retire_agent(&source_id).await;
        let forked_id = self.launch_agent(
            request_id,
            provider,
            ResolvedWorkspace {
                cwd,
                strategy,
                worktree_path,
                managed: managed_workspace,
            },
            provider_options,
            SessionLaunch::Fork(provider_session_id),
        );
        if let Some(agent) = forked_id.and_then(|agent_id| self.agents.get_mut(&agent_id)) {
            agent.pending_contexts = pending_contexts;
        }
    }

    async fn retire_agent(&mut self, agent_id: &str) {
        let Some(agent) = self.agents.get_mut(agent_id) else {
            return;
        };
        let _ = agent.commands.send(AgentCommand::Shutdown).await;
        if let Some(mut task) = agent.task.take()
            && tokio::time::timeout(SHUTDOWN_TIMEOUT, &mut task)
                .await
                .is_err()
        {
            task.abort();
            let _ = task.await;
        }
        agent.summary.state = AgentState::Disconnected;
        agent.summary.active_turn_id = None;
        agent.summary.pending_approvals = 0;
        agent.pending_questions = 0;
        agent.pending_contexts.clear();
        agent.summary.updated_at = timestamp();
        self.notify_state();
    }

    async fn archive_agent(&mut self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if matches!(
            agent.summary.state,
            AgentState::Starting
                | AgentState::Running
                | AgentState::WaitingInput
                | AgentState::WaitingApproval
        ) || agent.summary.pending_approvals > 0
            || agent.pending_questions > 0
        {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Only an inactive agent with no pending human request can be archived",
                None,
            ));
            return;
        }
        if agent.task.is_some() {
            self.retire_agent(&agent_id).await;
        }
        self.agents.remove(&agent_id);
        self.agent_order.retain(|candidate| candidate != &agent_id);
        self.send(success_response(
            request_id,
            json!({ "archived": true, "agent_id": agent_id }),
        ));
        self.notify_state();
    }

    async fn send_agent_input(&mut self, request_id: RequestId, params: Value, kind: InputKind) {
        let Ok(parsed) = serde_json::from_value::<TurnInputParams>(params) else {
            self.send(invalid_params(request_id, "invalid turn input parameters"));
            return;
        };
        if parsed.input.text.is_empty() {
            self.send(invalid_params(request_id, "input text must not be empty"));
            return;
        }
        let Some(agent) = self.agents.get(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let provider_options = match input_provider_options(agent, parsed.provider_options, kind) {
            Ok(options) => options,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let agent = self
            .agents
            .get_mut(&parsed.agent_id)
            .expect("validated agent must remain present");
        let queue_prompt = parsed.queue
            && kind == InputKind::Prompt
            && matches!(
                agent.summary.state,
                AgentState::Running | AgentState::WaitingInput | AgentState::WaitingApproval
            );
        let allowed = match kind {
            InputKind::Prompt => {
                queue_prompt
                    || matches!(
                        agent.summary.state,
                        AgentState::Idle | AgentState::Completed | AgentState::Interrupted
                    )
            }
            InputKind::Steer => agent.summary.state == AgentState::Running,
        };
        if !allowed {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent state does not allow this input",
                None,
            ));
            return;
        }
        if queue_prompt && agent.queued_prompts.len() >= 32 {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Prompt queue is full (32 pending)",
                None,
            ));
            return;
        }
        let cwd = Path::new(&agent.summary.cwd);
        let attachments =
            match merge_input_contexts(&agent.pending_contexts, parsed.input.attachments, cwd) {
                Ok(attachments) => attachments,
                Err(message) => {
                    self.send(invalid_params(request_id, message));
                    return;
                }
            };
        let input = QueuedPrompt {
            text: parsed.input.text,
            attachments,
            provider_options,
        };
        agent.pending_contexts.clear();
        if queue_prompt {
            agent.queued_prompts.push_back(input);
            let position = agent.queued_prompts.len();
            self.send(success_response(
                request_id,
                json!({ "accepted": true, "queued": true, "position": position }),
            ));
            return;
        }
        self.dispatch_agent_input(request_id, parsed.agent_id, input, kind)
            .await;
    }

    async fn dispatch_agent_input(
        &mut self,
        request_id: RequestId,
        agent_id: String,
        input: QueuedPrompt,
        kind: InputKind,
    ) {
        let agent = self
            .agents
            .get_mut(&agent_id)
            .expect("validated agent must remain present");
        let commands = agent.commands.clone();
        if kind == InputKind::Prompt {
            agent.summary.state = AgentState::Running;
            agent.summary.provider_options = input.provider_options.clone();
            if !agent.has_prompted {
                agent.has_prompted = true;
                if agent.summary.managed_workspace.is_none() {
                    agent.summary.title = prompt_title(&input.text);
                    agent.title_from_prompt = true;
                }
            }
            agent.summary.updated_at = timestamp();
        }
        let runtime_request_id = self.runtime_request(request_id.clone());
        let command = match kind {
            InputKind::Prompt => AgentCommand::Prompt {
                request_id: runtime_request_id.clone(),
                text: input.text,
                attachments: input.attachments,
                provider_options: input.provider_options,
            },
            InputKind::Steer => AgentCommand::Steer {
                request_id: runtime_request_id.clone(),
                text: input.text,
                attachments: input.attachments,
            },
        };
        if commands.send(command).await.is_err() {
            self.pending_runtime_requests.remove(&runtime_request_id);
            let agent = self
                .agents
                .get_mut(&agent_id)
                .expect("validated agent must remain present");
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Provider command channel is unavailable",
                None,
            ));
            self.notify_state();
            return;
        }
        if kind == InputKind::Prompt {
            self.notify_state();
        }
    }

    async fn interrupt_agent(&mut self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        self.cancel_queued_prompts(&agent_id);
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let commands = agent.commands.clone();
        let runtime_request_id = self.runtime_request(request_id.clone());
        if commands
            .send(AgentCommand::Interrupt {
                request_id: runtime_request_id.clone(),
            })
            .await
            .is_err()
        {
            self.pending_runtime_requests.remove(&runtime_request_id);
            let agent = self
                .agents
                .get_mut(&agent_id)
                .expect("validated agent must remain present");
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Provider command channel is unavailable",
                None,
            ));
            self.notify_state();
        }
    }

    async fn respond_approval(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ApprovalResponseParams>(params) else {
            self.send(invalid_params(request_id, "invalid approval response"));
            return;
        };
        if !matches!(parsed.decision.as_str(), "allow" | "deny" | "defer") {
            self.send(invalid_params(request_id, "invalid approval decision"));
            return;
        }
        if parsed.agent_id.is_empty()
            || parsed.approval_id.is_empty()
            || parsed
                .updated_input
                .as_ref()
                .is_some_and(|value| !value.is_object())
            || parsed
                .message
                .as_ref()
                .is_some_and(|message| message.chars().count() > 4_096)
        {
            self.send(invalid_params(request_id, "invalid approval response"));
            return;
        }
        let Some(agent) = self.agents.get(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let commands = agent.commands.clone();
        let runtime_request_id = self.runtime_request(request_id.clone());
        let command = AgentCommand::Approval {
            request_id: runtime_request_id.clone(),
            action_id: parsed.approval_id,
            decision: parsed.decision,
            updated_input: parsed.updated_input,
            message: parsed.message,
        };
        if commands.send(command).await.is_err() {
            self.pending_runtime_requests.remove(&runtime_request_id);
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    async fn respond_question(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<QuestionResponseParams>(params) else {
            self.send(invalid_params(request_id, "invalid question response"));
            return;
        };
        if !matches!(parsed.decision.as_str(), "answer" | "deny") {
            self.send(invalid_params(request_id, "invalid question decision"));
            return;
        }
        if parsed.agent_id.is_empty()
            || parsed.question_id.is_empty()
            || !valid_question_answers(&parsed.answers)
            || parsed
                .message
                .as_ref()
                .is_some_and(|message| message.chars().count() > 4_096)
        {
            self.send(invalid_params(request_id, "invalid question response"));
            return;
        }
        let Some(agent) = self.agents.get(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let commands = agent.commands.clone();
        let runtime_request_id = self.runtime_request(request_id.clone());
        let command = AgentCommand::Question {
            request_id: runtime_request_id.clone(),
            action_id: parsed.question_id,
            decision: parsed.decision,
            answers: parsed.answers,
            message: parsed.message,
        };
        if commands.send(command).await.is_err() {
            self.pending_runtime_requests.remove(&runtime_request_id);
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    fn add_context(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ContextParams>(params) else {
            self.send(invalid_params(request_id, "invalid editor context"));
            return;
        };
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if agent.task.is_none() || agent.summary.state == AgentState::Disconnected {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Editor context requires a live agent",
                None,
            ));
            return;
        }
        let context = match validate_context(parsed.context, Path::new(&agent.summary.cwd)) {
            Ok(context) => context,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let mut contexts = agent.pending_contexts.clone();
        contexts.push(context.clone());
        if let Err(message) = validate_context_collection(&contexts) {
            self.send(invalid_params(request_id, message));
            return;
        }
        agent.pending_contexts = contexts;
        let count = agent.pending_contexts.len();
        self.send(success_response(
            request_id,
            json!({
                "queued": true,
                "count": count,
                "context": context,
            }),
        ));
    }

    async fn workspace_diff(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<WorkspaceDiffParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid workspace diff parameters",
            ));
            return;
        };
        let cwd = match canonical_directory(&parsed.cwd) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        self.diff_directory(request_id, &cwd).await;
    }

    async fn diff(&self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        self.diff_directory(request_id, Path::new(&agent.summary.cwd))
            .await;
    }

    async fn diff_directory(&self, request_id: RequestId, cwd: &Path) {
        let mut command = tokio::process::Command::new("git");
        command
            .arg("-C")
            .arg(cwd)
            .args(["diff", "--no-ext-diff", "--no-textconv", "--"])
            .kill_on_drop(true);
        let output = tokio::time::timeout(DIFF_TIMEOUT, command.output()).await;
        let Ok(Ok(output)) = output else {
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Workspace diff timed out or could not be started",
                None,
            ));
            return;
        };
        if !output.status.success() {
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Workspace diff is unavailable for this directory",
                None,
            ));
            return;
        }
        let truncated = output.stdout.len() > MAX_DIFF_BYTES;
        let bytes = &output.stdout[..output.stdout.len().min(MAX_DIFF_BYTES)];
        let diff = String::from_utf8_lossy(bytes).into_owned();
        self.send(success_response(
            request_id,
            json!({ "cwd": cwd, "diff": diff, "truncated": truncated }),
        ));
    }

    fn command_channel_failed(&mut self, agent_id: &str, request_id: RequestId) {
        if let Some(agent) = self.agents.get_mut(agent_id) {
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            agent.pending_contexts.clear();
        }
        self.send(error_response(
            Some(request_id),
            -32_020,
            "Provider command channel is unavailable",
            None,
        ));
        self.notify_state();
    }

    fn replay(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ReplayParams>(params) else {
            self.send(invalid_params(request_id, "invalid replay parameters"));
            return;
        };
        match self.replay.replay_after(parsed.after_sequence) {
            ReplayResult::Events(events) => {
                self.send(success_response(request_id, json!({ "events": events })));
            }
            ReplayResult::ResyncRequired { oldest, latest } => self.send(error_response(
                Some(request_id),
                -32_014,
                "Replay cursor is outside the retained window",
                Some(json!({ "oldest": oldest, "latest": latest })),
            )),
        }
    }

    fn handle_runtime_event(&mut self, runtime: RuntimeEvent) {
        match runtime {
            RuntimeEvent::Started {
                request_id,
                agent_id,
                provider_session_id,
                runtime,
            } => {
                let provider = self
                    .agents
                    .get(&agent_id)
                    .map(|agent| agent.summary.provider);
                let stale_ids = self
                    .agents
                    .iter()
                    .filter(|(candidate_id, candidate)| {
                        *candidate_id != &agent_id
                            && candidate.task.is_none()
                            && candidate.summary.state == AgentState::Disconnected
                            && Some(candidate.summary.provider) == provider
                            && candidate.summary.provider_session_id.as_deref()
                                == Some(provider_session_id.as_str())
                    })
                    .map(|(candidate_id, _)| candidate_id.clone())
                    .collect::<Vec<_>>();
                for stale_id in &stale_ids {
                    self.agents.remove(stale_id);
                }
                if !stale_ids.is_empty() {
                    self.agent_order
                        .retain(|candidate_id| !stale_ids.contains(candidate_id));
                }
                let summary = {
                    let Some(agent) = self.agents.get_mut(&agent_id) else {
                        return;
                    };
                    agent.summary.provider_session_id = Some(provider_session_id);
                    agent.summary.runtime = Some(runtime);
                    agent.summary.state = AgentState::Idle;
                    agent.summary.updated_at = timestamp();
                    agent.summary.clone()
                };
                self.send_runtime_response(&request_id, |public_id| {
                    success_response(public_id, json!({ "agent": summary }))
                });
                self.notify_state();
            }
            RuntimeEvent::Response { request_id, result } => {
                self.queued_runtime_requests.remove(&request_id);
                self.send_runtime_response(&request_id, |public_id| {
                    success_response(public_id, result)
                });
            }
            RuntimeEvent::RequestFailed {
                request_id,
                agent_id,
                code,
                message,
                fail_agent,
            } => {
                if self.queued_runtime_requests.remove(&request_id) {
                    self.handle_provider_failure(
                        agent_id,
                        "Queued prompt could not start; queued follow-ups were cancelled",
                    );
                    return;
                }
                if fail_agent {
                    self.cancel_queued_prompts(&agent_id);
                }
                if fail_agent && let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.summary.state = AgentState::Failed;
                    agent.summary.active_turn_id = None;
                    agent.summary.updated_at = timestamp();
                    let _ = agent.commands.try_send(AgentCommand::Shutdown);
                }
                self.send_runtime_response(&request_id, |public_id| {
                    error_response(Some(public_id), code, &message, None)
                });
                if fail_agent {
                    self.notify_state();
                }
            }
            RuntimeEvent::ProviderEvent(event) => self.handle_provider_event(event),
            RuntimeEvent::ProviderFailed { agent_id, message } => {
                self.handle_provider_failure(agent_id, message);
            }
            RuntimeEvent::Stopped { agent_id } => {
                self.cancel_queued_prompts(&agent_id);
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.task.take();
                    agent.pending_contexts.clear();
                    if agent.summary.state != AgentState::Disconnected {
                        agent.summary.state = AgentState::Disconnected;
                        agent.summary.active_turn_id = None;
                        agent.summary.updated_at = timestamp();
                        self.notify_state();
                    }
                }
            }
        }
    }

    fn handle_provider_event(&mut self, mut event: EventEnvelope) {
        if self.mode == BrokerMode::Durable
            && self.phase != ConnectionPhase::Ready
            && matches!(
                event.event_type.as_str(),
                "approval.requested" | "question.requested"
            )
            && let Some(agent) = self.agents.get(&event.agent_id)
        {
            queue_client_disconnect(&agent.commands);
        }
        let sequence = self.replay.push(event.clone());
        event.sequence = sequence;
        let state_changed = self.apply_event_state(&event);
        let agent_id = event.agent_id.clone();
        let completed = event.event_type == "turn.completed";
        let failed = event.event_type == "turn.failed";
        if self.phase == ConnectionPhase::Ready {
            self.send(json!({
                "jsonrpc": "2.0",
                "method": "agent/event",
                "params": event,
            }));
        }
        if completed {
            if self.agents.get(&agent_id).is_some_and(|agent| {
                agent.summary.state == AgentState::Completed
                    && agent.summary.pending_approvals == 0
                    && agent.pending_questions == 0
            }) {
                self.dispatch_queued_prompt(&agent_id);
            } else {
                self.cancel_queued_prompts(&agent_id);
            }
        } else if failed {
            self.cancel_queued_prompts(&agent_id);
        }
        if state_changed {
            self.notify_state();
        }
    }

    fn dispatch_queued_prompt(&mut self, agent_id: &str) {
        let Some(agent) = self.agents.get_mut(agent_id) else {
            return;
        };
        let Some(prompt) = agent.queued_prompts.pop_front() else {
            return;
        };
        let request_id = RequestId::String(format!("queued:{}", self.next_runtime_request));
        self.next_runtime_request = self
            .next_runtime_request
            .checked_add(1)
            .expect("runtime request sequence overflow");
        let provider_options = prompt.provider_options.clone();
        let command = AgentCommand::Prompt {
            request_id: request_id.clone(),
            text: prompt.text,
            attachments: prompt.attachments,
            provider_options: prompt.provider_options,
        };
        if agent.commands.try_send(command).is_err() {
            self.handle_provider_failure(
                agent_id.to_owned(),
                "Queued prompt could not start; provider command channel unavailable",
            );
            return;
        }
        self.queued_runtime_requests.insert(request_id);
        agent.summary.state = AgentState::Running;
        agent.summary.provider_options = provider_options;
        agent.summary.updated_at = timestamp();
    }

    fn cancel_queued_prompts(&mut self, agent_id: &str) {
        let Some(agent) = self.agents.get_mut(agent_id) else {
            return;
        };
        let count = agent.queued_prompts.len();
        agent.queued_prompts.clear();
        if count > 0 {
            let event = EventEnvelope::new(
                timestamp(),
                agent_id.to_owned(),
                agent.summary.provider,
                "broker.notice".to_owned(),
                json!({ "message": format!("Cancelled {count} queued prompt(s)") }),
                json!({ "kind": "broker", "redacted": true }),
            );
            self.handle_provider_event(event);
        }
    }

    fn handle_provider_failure(&mut self, agent_id: String, message: &'static str) {
        self.cancel_queued_prompts(&agent_id);
        let Some(agent) = self.agents.get_mut(&agent_id) else {
            return;
        };
        agent.summary.state = AgentState::Disconnected;
        agent.summary.active_turn_id = None;
        agent.summary.pending_approvals = 0;
        agent.pending_questions = 0;
        agent.summary.updated_at = timestamp();
        agent.pending_contexts.clear();
        let mut event = EventEnvelope::new(
            timestamp(),
            agent_id,
            agent.summary.provider,
            "broker.error".to_owned(),
            json!({ "message": message }),
            json!({ "kind": "broker", "redacted": true }),
        );
        let sequence = self.replay.push(event.clone());
        event.sequence = sequence;
        if self.phase == ConnectionPhase::Ready {
            self.send(json!({
                "jsonrpc": "2.0",
                "method": "agent/event",
                "params": event,
            }));
        }
        self.notify_state();
    }

    fn apply_event_state(&mut self, event: &EventEnvelope) -> bool {
        let Some(agent) = self.agents.get_mut(&event.agent_id) else {
            return false;
        };
        let previous_state = agent.summary.state;
        let previous_turn = agent.summary.active_turn_id.clone();
        let previous_approvals = agent.summary.pending_approvals;
        let previous_questions = agent.pending_questions;
        match event.event_type.as_str() {
            "turn.started" => {
                agent.summary.state = AgentState::Running;
                agent.summary.active_turn_id = event
                    .payload
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .or_else(|| event.payload.get("turnId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
            "turn.completed" => {
                agent.summary.state = if event.payload["turn"]["status"] == "interrupted"
                    || event.payload["subtype"] == "interrupted"
                {
                    AgentState::Interrupted
                } else {
                    AgentState::Completed
                };
                agent.summary.active_turn_id = None;
            }
            "turn.failed" => {
                agent.summary.state = AgentState::Failed;
                agent.summary.active_turn_id = None;
            }
            "approval.requested" => {
                agent.summary.pending_approvals = agent.summary.pending_approvals.saturating_add(1);
                agent.summary.state = AgentState::WaitingApproval;
            }
            "question.requested" => {
                agent.pending_questions = agent.pending_questions.saturating_add(1);
                if agent.summary.pending_approvals == 0 {
                    agent.summary.state = AgentState::WaitingInput;
                }
            }
            "approval.resolved" => {
                agent.summary.pending_approvals = agent.summary.pending_approvals.saturating_sub(1);
                restore_waiting_state(agent);
            }
            "question.resolved" => {
                agent.pending_questions = agent.pending_questions.saturating_sub(1);
                restore_waiting_state(agent);
            }
            _ => {}
        }
        let changed = previous_state != agent.summary.state
            || previous_turn != agent.summary.active_turn_id
            || previous_approvals != agent.summary.pending_approvals
            || previous_questions != agent.pending_questions;
        if changed {
            agent.summary.updated_at = timestamp();
        }
        changed
    }

    fn summaries(&self) -> Vec<AgentSummary> {
        self.agent_order
            .iter()
            .filter_map(|agent_id| self.agents.get(agent_id))
            .map(|agent| agent.summary.clone())
            .collect()
    }

    fn notify_state(&self) {
        let summaries = self.summaries();
        let mut registry_failed = false;
        let registry_bytes = if let Some(registry) = &self.registry {
            let registry_summaries = self
                .agent_order
                .iter()
                .filter_map(|agent_id| self.agents.get(agent_id))
                .map(|agent| {
                    let mut summary = agent.summary.clone();
                    if agent.title_from_prompt {
                        summary.title = directory_title(Path::new(&summary.cwd), summary.provider);
                    }
                    summary
                })
                .collect::<Vec<_>>();
            if registry.persist(&registry_summaries).is_err() {
                registry_failed = true;
                eprintln!("agent-manager-broker: durable registry persistence failed");
            }
            registry.bytes()
        } else {
            0
        };
        if let Some(status) = &self.status {
            let result = if registry_failed {
                status.failure(
                    "registry_persistence_failed",
                    summaries.len() as u64,
                    registry_bytes,
                )
            } else {
                status.success("running", summaries.len() as u64, registry_bytes)
            };
            if result.is_err() {
                eprintln!("agent-manager-broker: durable status persistence failed");
            }
        }
        if self.phase == ConnectionPhase::Ready {
            self.send(json!({
                "jsonrpc": "2.0",
                "method": "broker/state",
                "params": { "agents": summaries },
            }));
        }
    }

    fn send(&self, message: Value) {
        if let Some(output) = &self.output {
            let _ = output.send(message);
        }
    }

    fn runtime_request(&mut self, public_id: RequestId) -> RequestId {
        let request_id = RequestId::String(format!(
            "broker:{}:{}",
            self.connection_generation, self.next_runtime_request
        ));
        self.next_runtime_request = self
            .next_runtime_request
            .checked_add(1)
            .expect("runtime request sequence overflow");
        self.pending_runtime_requests.insert(
            request_id.clone(),
            PendingRuntimeRequest {
                generation: self.connection_generation,
                public_id,
            },
        );
        request_id
    }

    fn send_runtime_response(
        &mut self,
        request_id: &RequestId,
        response: impl FnOnce(RequestId) -> Value,
    ) {
        let Some(pending) = self.pending_runtime_requests.remove(request_id) else {
            return;
        };
        if pending.generation == self.connection_generation && self.output.is_some() {
            self.send(response(pending.public_id));
        }
    }

    pub(crate) async fn shutdown_agents(&mut self) {
        for agent in self.agents.values() {
            let _ = agent.commands.send(AgentCommand::Shutdown).await;
        }
        for agent in self.agents.values_mut() {
            let Some(mut task) = agent.task.take() else {
                continue;
            };
            if tokio::time::timeout(SHUTDOWN_TIMEOUT, &mut task)
                .await
                .is_err()
            {
                task.abort();
                let _ = task.await;
            }
        }
    }

    pub(crate) fn durable_counts(&self) -> (u64, u64) {
        (
            self.agents.len() as u64,
            self.registry.as_ref().map_or(0, RegistryStore::bytes),
        )
    }
}

fn queue_client_disconnect(commands: &mpsc::Sender<AgentCommand>) {
    if commands.try_send(AgentCommand::ClientDisconnected).is_err() {
        let commands = commands.clone();
        tokio::spawn(async move {
            let _ = commands.send(AgentCommand::ClientDisconnected).await;
        });
    }
}

fn restore_waiting_state(agent: &mut ManagedAgent) {
    if matches!(
        agent.summary.state,
        AgentState::Disconnected | AgentState::Failed
    ) {
        return;
    }
    agent.summary.state = if agent.summary.pending_approvals > 0 {
        AgentState::WaitingApproval
    } else if agent.pending_questions > 0 {
        AgentState::WaitingInput
    } else if agent.summary.active_turn_id.is_some() {
        AgentState::Running
    } else {
        AgentState::Idle
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputKind {
    Prompt,
    Steer,
}

fn input_provider_options(
    agent: &ManagedAgent,
    requested: Option<ProviderOptions>,
    kind: InputKind,
) -> Result<ProviderOptions, &'static str> {
    let current = &agent.summary.provider_options;
    let options = requested.unwrap_or_else(|| current.clone());
    validate_provider_options(agent.summary.provider, &options)?;
    if kind == InputKind::Steer && &options != current {
        return Err("provider options apply to ordinary prompts, not active-turn steering");
    }
    Ok(options)
}

fn merge_input_contexts(
    pending: &[Value],
    attachments: Vec<Value>,
    cwd: &Path,
) -> Result<Vec<Value>, &'static str> {
    let mut contexts = pending.to_vec();
    for attachment in attachments {
        contexts.push(validate_context(attachment, cwd)?);
    }
    validate_context_collection(&contexts)?;
    Ok(contexts)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitializeParams {
    protocol_version: u32,
    client: ClientIdentity,
    #[serde(default)]
    last_sequence: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientIdentity {
    name: String,
    #[serde(default, rename = "title")]
    _title: Option<String>,
    version: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StartParams {
    provider: Provider,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    workspace_strategy: Option<WorkspaceStrategy>,
    #[serde(default)]
    worktree_path: Option<String>,
    #[serde(default)]
    managed_workspace: Option<ManagedWorkspaceParams>,
    #[serde(default)]
    provider_options: Option<ProviderOptions>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManagedWorkspaceParams {
    repository: String,
    task_id: String,
    #[serde(default)]
    resume: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderSessionListParams {
    provider: Provider,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    active_only: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderModelListParams {
    provider: Provider,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderSessionDeleteParams {
    provider: Provider,
    provider_session_id: String,
    cwd: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkspaceDiffParams {
    cwd: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResumeParams {
    provider: Provider,
    provider_session_id: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    workspace_strategy: Option<WorkspaceStrategy>,
    #[serde(default)]
    worktree_path: Option<String>,
    #[serde(default)]
    managed_workspace: Option<ManagedWorkspaceParams>,
    #[serde(default)]
    provider_options: Option<ProviderOptions>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentIdParams {
    agent_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HistoryParams {
    agent_id: String,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TurnInputParams {
    #[serde(default)]
    queue: bool,
    agent_id: String,
    input: TurnInput,
    #[serde(default)]
    provider_options: Option<ProviderOptions>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TurnInput {
    text: String,
    attachments: Vec<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovalResponseParams {
    agent_id: String,
    approval_id: String,
    decision: String,
    #[serde(default)]
    updated_input: Option<Value>,
    #[serde(default)]
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct QuestionResponseParams {
    agent_id: String,
    question_id: String,
    #[serde(default = "answer_decision")]
    decision: String,
    answers: serde_json::Map<String, Value>,
    #[serde(default)]
    message: Option<String>,
}

fn answer_decision() -> String {
    "answer".to_owned()
}

fn valid_question_answers(answers: &serde_json::Map<String, Value>) -> bool {
    answers.len() <= 32
        && answers.values().all(|answer| match answer {
            Value::String(answer) => answer.chars().count() <= 16_384,
            Value::Array(answers) => {
                answers.len() <= 32
                    && answers.iter().all(|answer| {
                        answer
                            .as_str()
                            .is_some_and(|answer| answer.chars().count() <= 4_096)
                    })
            }
            _ => false,
        })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextParams {
    agent_id: String,
    context: Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplayParams {
    after_sequence: u64,
}

fn parse_agent_id(params: Value) -> Option<String> {
    serde_json::from_value::<AgentIdParams>(params)
        .ok()
        .map(|params| params.agent_id)
        .filter(|agent_id| !agent_id.is_empty())
}

fn canonical_directory(raw: &str) -> Result<PathBuf, &'static str> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("cwd must be absolute");
    }
    let canonical = path.canonicalize().map_err(|_| "cwd does not exist")?;
    if !canonical.is_dir() {
        return Err("cwd must identify a directory");
    }
    Ok(canonical)
}

fn validate_workspace(
    strategy: WorkspaceStrategy,
    worktree_path: Option<&str>,
    cwd: &Path,
    mode: BrokerMode,
) -> Result<Option<String>, &'static str> {
    match strategy {
        WorkspaceStrategy::Shared if worktree_path.is_none() => Ok(None),
        WorkspaceStrategy::Shared => Err("shared strategy cannot specify worktree_path"),
        WorkspaceStrategy::Worktree => {
            let Some(raw) = worktree_path else {
                return Err("worktree strategy requires worktree_path");
            };
            let worktree = canonical_directory(raw)?;
            if worktree != cwd {
                return Err("worktree_path must equal the agent cwd");
            }
            if mode == BrokerMode::Durable && !is_linked_git_worktree(&worktree) {
                return Err("durable worktree strategy requires a linked Git worktree");
            }
            Ok(Some(worktree.to_string_lossy().into_owned()))
        }
    }
}

fn checkout_identity(strategy: WorkspaceStrategy, cwd: &Path) -> PathBuf {
    if strategy == WorkspaceStrategy::Worktree {
        return cwd.to_owned();
    }
    git_top_level(cwd).unwrap_or_else(|| cwd.to_owned())
}

fn is_codex_directory_resume(provider: Provider, launch: &SessionLaunch, cwd: &Path) -> bool {
    // A saved Codex CLI conversation may live outside any Git checkout.
    // Only this resume bypasses the administrator's shared-checkout policy.
    if provider != Provider::Codex || !matches!(launch, SessionLaunch::Resume(_)) {
        return false;
    }
    // Broken Git markers must not turn a checkout into an allowed directory.
    // Also preserve the workstation's managed worktree namespace.
    if std::env::var_os("HOME")
        .is_some_and(|home| cwd.starts_with(Path::new(&home).join("worktrees")))
    {
        return false;
    }
    if cwd.ancestors().any(|path| {
        !matches!(
            fs::symlink_metadata(path.join(".git")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound
        )
    }) {
        return false;
    }
    git_top_level(cwd).is_none()
}

fn git_top_level(cwd: &Path) -> Option<PathBuf> {
    git_rev_parse_path(cwd, "--show-toplevel")
}

fn git_rev_parse_path(cwd: &Path, argument: &str) -> Option<PathBuf> {
    let output = StdCommand::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["rev-parse", argument])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&output.stdout);
    let raw = Path::new(raw.trim());
    let path = if raw.is_absolute() {
        raw.to_owned()
    } else {
        cwd.join(raw)
    };
    path.canonicalize().ok()
}

fn is_linked_git_worktree(path: &Path) -> bool {
    let marker = path.join(".git");
    let Ok(metadata) = fs::symlink_metadata(&marker) else {
        return false;
    };
    if !metadata.file_type().is_file() || metadata.len() > 8_192 {
        return false;
    }
    let Ok(contents) = fs::read_to_string(marker) else {
        return false;
    };
    if !contents.starts_with("gitdir: ") {
        return false;
    }
    let Some(root) = git_top_level(path) else {
        return false;
    };
    let Some(git_directory) = git_rev_parse_path(path, "--git-dir") else {
        return false;
    };
    let Some(common_directory) = git_rev_parse_path(path, "--git-common-dir") else {
        return false;
    };
    root == path && git_directory != common_directory
}

fn validate_context(context: Value, cwd: &Path) -> Result<Value, &'static str> {
    let object = context.as_object().ok_or("context must be an object")?;
    let kind = object
        .get("kind")
        .and_then(Value::as_str)
        .ok_or("context.kind must be a non-empty string")?;
    if !matches!(kind, "buffer" | "range" | "diagnostics" | "diff") {
        return Err("context kind must be buffer, range, diagnostics, or diff");
    }
    let payload = object
        .get("payload")
        .and_then(Value::as_object)
        .ok_or("context.payload must be an object")?;
    let raw_path = payload
        .get("path")
        .or_else(|| payload.get("cwd"))
        .and_then(Value::as_str)
        .ok_or("editor context must identify its path")?;
    let path = canonical_context_path(raw_path)?;
    if !path.starts_with(cwd) {
        return Err("editor context path escapes the agent cwd");
    }
    match kind {
        "buffer" | "range" if !payload.get("text").is_some_and(Value::is_string) => {
            return Err("buffer and range context require text");
        }
        "diagnostics" if !payload.get("diagnostics").is_some_and(Value::is_array) => {
            return Err("diagnostics context requires a diagnostics array");
        }
        "diff" if !payload.get("diff").is_some_and(Value::is_string) => {
            return Err("diff context requires diff text");
        }
        _ => {}
    }
    if serde_json::to_vec(&context).map_or(true, |encoded| encoded.len() > MAX_CONTEXT_BYTES) {
        return Err("editor context exceeds the size limit");
    }
    Ok(context)
}

fn validate_context_collection(contexts: &[Value]) -> Result<(), &'static str> {
    if contexts.len() > MAX_CONTEXT_ITEMS {
        return Err("too many editor context items");
    }
    if serde_json::to_vec(contexts).map_or(true, |encoded| encoded.len() > MAX_CONTEXT_BYTES) {
        return Err("combined editor context exceeds the size limit");
    }
    Ok(())
}

fn canonical_context_path(raw: &str) -> Result<PathBuf, &'static str> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("editor context path must be absolute");
    }
    if path.exists() {
        return path
            .canonicalize()
            .map_err(|_| "editor context path could not be resolved");
    }
    let parent = path
        .parent()
        .ok_or("editor context path has no parent")?
        .canonicalize()
        .map_err(|_| "editor context parent does not exist")?;
    let name = path
        .file_name()
        .ok_or("editor context path has no file name")?;
    Ok(parent.join(name))
}

fn validate_provider_options(
    provider: Provider,
    options: &ProviderOptions,
) -> Result<(), &'static str> {
    if options.model.as_ref().is_some_and(|value| {
        value.is_empty() || value.len() > 256 || value.chars().any(char::is_control)
    }) {
        return Err("provider model is invalid");
    }
    if options.effort.as_ref().is_some_and(|value| {
        value.is_empty() || value.len() > 64 || value.chars().any(char::is_control)
    }) {
        return Err("provider effort is invalid");
    }
    if provider == Provider::Claude
        && options
            .effort
            .as_deref()
            .is_some_and(|value| !matches!(value, "low" | "medium" | "high" | "xhigh" | "max"))
    {
        return Err("Claude effort must be low, medium, high, xhigh, or max");
    }
    Ok(())
}

fn prompt_title(prompt: &str) -> String {
    let title = prompt
        .split_whitespace()
        .take(6)
        .collect::<Vec<_>>()
        .join(" ");
    let title = title.chars().take(96).collect::<String>();
    if title.is_empty() {
        "session".to_owned()
    } else {
        title
    }
}

fn directory_title(cwd: &Path, provider: Provider) -> String {
    cwd.file_name()
        .and_then(|name| name.to_str())
        .map_or_else(|| provider.to_string(), str::to_owned)
}

fn capabilities(provider: Provider) -> Vec<Capability> {
    vec![
        available(CapabilityName::Streaming),
        available(CapabilityName::MultiTurn),
        available(CapabilityName::History),
        available(CapabilityName::Resume),
        available(CapabilityName::Fork),
        available(CapabilityName::Interrupt),
        available(CapabilityName::Steer),
        available(CapabilityName::Approvals),
        available(CapabilityName::Questions),
        Capability {
            name: CapabilityName::Usage,
            available: true,
            reason: None,
        },
        Capability {
            name: CapabilityName::FileChanges,
            available: true,
            reason: (provider == Provider::Claude).then(|| {
                "Projected from Claude tool and hook events when paths are supplied".to_owned()
            }),
        },
        available(CapabilityName::Diff),
        available(CapabilityName::Replay),
    ]
}

const fn available(name: CapabilityName) -> Capability {
    Capability {
        name,
        available: true,
        reason: None,
    }
}

fn timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn success_response(id: RequestId, result: Value) -> Value {
    let mut response = serde_json::Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert(
        "id".to_owned(),
        serde_json::to_value(id).unwrap_or(Value::Null),
    );
    response.insert("result".to_owned(), result);
    Value::Object(response)
}

fn error_response(id: Option<RequestId>, code: i64, message: &str, data: Option<Value>) -> Value {
    let mut error = json!({ "code": code, "message": message });
    if let Some(data) = data {
        error["data"] = data;
    }
    let mut response = serde_json::Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert(
        "id".to_owned(),
        serde_json::to_value(id).unwrap_or(Value::Null),
    );
    response.insert("error".to_owned(), error);
    Value::Object(response)
}

fn invalid_params(id: RequestId, reason: &str) -> Value {
    error_response(
        Some(id),
        -32_602,
        "Invalid params",
        Some(json!({ "reason": reason })),
    )
}

fn agent_not_found(id: RequestId) -> Value {
    error_response(Some(id), -32_015, "Agent was not found", None)
}

impl std::fmt::Display for Provider {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        })
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::json;
    use tokio::sync::mpsc;

    use super::{
        Broker, BrokerMode, EmbeddedConfig, MAX_CONTEXT_BYTES, MAX_CONTEXT_ITEMS,
        valid_question_answers, validate_context, validate_context_collection,
    };
    use crate::protocol::{EventEnvelope, Provider};

    fn fixture_cwd() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .canonicalize()
            .expect("canonical fixture cwd")
    }

    #[test]
    fn validates_context_shape_and_rejects_workspace_escape() {
        let cwd = fixture_cwd();
        let valid = json!({
            "kind": "range",
            "payload": {
                "path": cwd.join("Cargo.toml"),
                "start_line": 1,
                "end_line": 1,
                "text": "[package]"
            }
        });
        assert!(validate_context(valid, &cwd).is_ok());

        let outside = cwd.parent().expect("workspace root").join("Cargo.toml");
        let escaped = json!({
            "kind": "buffer",
            "payload": { "path": outside, "text": "[workspace]" }
        });
        assert_eq!(
            validate_context(escaped, &cwd),
            Err("editor context path escapes the agent cwd")
        );
        assert_eq!(
            validate_context(
                json!({ "kind": "buffer", "payload": { "path": cwd.join("Cargo.toml") } }),
                &cwd,
            ),
            Err("buffer and range context require text")
        );
    }

    #[test]
    fn bounds_context_item_count_and_encoded_size() {
        let cwd = fixture_cwd();
        let oversized = json!({
            "kind": "buffer",
            "payload": {
                "path": cwd.join("Cargo.toml"),
                "text": "x".repeat(MAX_CONTEXT_BYTES)
            }
        });
        assert_eq!(
            validate_context(oversized, &cwd),
            Err("editor context exceeds the size limit")
        );

        let items = (0..=MAX_CONTEXT_ITEMS)
            .map(|_| json!({ "kind": "buffer", "payload": {} }))
            .collect::<Vec<_>>();
        assert_eq!(
            validate_context_collection(&items),
            Err("too many editor context items")
        );
    }

    #[test]
    fn validates_public_question_answer_shapes() {
        let valid = serde_json::from_value(json!({
            "mode": "safe",
            "checks": ["format", "test"]
        }))
        .expect("answer map");
        assert!(valid_question_answers(&valid));

        let invalid = serde_json::from_value(json!({ "mode": 7 })).expect("answer map");
        assert!(!valid_question_answers(&invalid));
        let too_many = serde_json::from_value(json!({
            "checks": (0..=32).map(|index| index.to_string()).collect::<Vec<_>>()
        }))
        .expect("answer map");
        assert!(!valid_question_answers(&too_many));
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn prompt_queue_is_fifo_bounded_and_cancels_on_failure() {
        for provider in [Provider::Codex, Provider::Claude] {
            let summary = serde_json::from_value(json!({
                "id": "queue-agent", "provider": provider, "cwd": fixture_cwd(),
                "workspace_strategy": "shared", "title": "queue fixture", "state": "running",
                "pending_approvals": 0, "unread_events": 0, "capabilities": [],
                "created_at": "2026-09-08T00:00:00Z", "updated_at": "2026-09-08T00:00:00Z",
            }))
            .expect("queue agent summary");
            let (runtime, _) = mpsc::unbounded_channel();
            let mut broker = Broker::new(
                EmbeddedConfig::default(),
                BrokerMode::Embedded,
                runtime,
                None,
                vec![summary],
                None,
            );
            let (commands, mut received) = mpsc::channel(4);
            broker.agents.get_mut("queue-agent").unwrap().commands = commands;
            let (output, mut responses) = mpsc::unbounded_channel();
            broker.output = Some(output);
            broker.phase = super::ConnectionPhase::Ready;
            let fixture: serde_json::Value = serde_json::from_str(include_str!(
                "../../../protocol/broker/v1/fixtures/queued-prompt.request.json"
            ))
            .expect("queued prompt request fixture");
            let mut params = fixture["params"].clone();
            params["queue"] = json!(false);
            broker
                .send_agent_input(
                    super::RequestId::Integer(41),
                    params,
                    super::InputKind::Prompt,
                )
                .await;
            assert_eq!(responses.recv().await.unwrap()["error"]["code"], -32_013);
            let context = json!({ "kind": "buffer", "payload": { "path": fixture_cwd().join("Cargo.toml"), "text": "captured context" } });
            broker
                .agents
                .get_mut("queue-agent")
                .unwrap()
                .pending_contexts
                .push(context.clone());
            let mut malformed = fixture["params"].clone();
            malformed["queue"] = json!("yes");
            broker
                .send_agent_input(
                    super::RequestId::Integer(43),
                    malformed,
                    super::InputKind::Prompt,
                )
                .await;
            assert_eq!(responses.recv().await.unwrap()["error"]["code"], -32_602);
            assert_eq!(
                broker.agents["queue-agent"].pending_contexts,
                vec![context.clone()]
            );
            for position in 1..=33 {
                let mut params = fixture["params"].clone();
                params["input"]["text"] = json!(format!("prompt {position}"));
                broker
                    .send_agent_input(
                        super::RequestId::Integer(42),
                        params,
                        super::InputKind::Prompt,
                    )
                    .await;
                let response = responses.recv().await.unwrap();
                if position <= 32 {
                    assert_eq!(response["result"]["queued"], true);
                    assert_eq!(response["result"]["position"], position);
                    if position == 1 {
                        let expected: serde_json::Value = serde_json::from_str(include_str!(
                            "../../../protocol/broker/v1/fixtures/queued-prompt.response.json"
                        ))
                        .expect("queued prompt response fixture");
                        assert_eq!(response, expected);
                    }
                } else {
                    assert_eq!(response["error"]["code"], -32_013);
                }
            }
            assert!(
                received.try_recv().is_err(),
                "nothing sent during active turn"
            );
            assert!(broker.agents["queue-agent"].pending_contexts.is_empty());
            for position in 1..=2 {
                broker.handle_provider_event(EventEnvelope::new(
                    "2026-09-08T00:00:00Z".to_owned(),
                    "queue-agent".to_owned(),
                    provider,
                    "turn.completed".to_owned(),
                    json!({}),
                    json!({}),
                ));
                let super::AgentCommand::Prompt {
                    request_id,
                    text,
                    attachments,
                    ..
                } = received.recv().await.unwrap()
                else {
                    panic!("expected queued prompt");
                };
                assert_eq!(text, format!("prompt {position}"));
                assert_eq!(
                    attachments,
                    if position == 1 {
                        vec![context.clone()]
                    } else {
                        vec![]
                    }
                );
                broker.handle_runtime_event(super::RuntimeEvent::Response {
                    request_id,
                    result: json!({"accepted": true}),
                });
                assert_eq!(
                    broker.agents["queue-agent"].summary.state,
                    super::AgentState::Running
                );
            }
            broker.handle_provider_event(EventEnvelope::new(
                "2026-09-08T00:00:00Z".to_owned(),
                "queue-agent".to_owned(),
                provider,
                "turn.failed".to_owned(),
                json!({}),
                json!({}),
            ));
            assert!(broker.agents["queue-agent"].queued_prompts.is_empty());
            assert!(
                received.try_recv().is_err(),
                "failure must not start next queued prompt"
            );
            assert!(broker.queued_runtime_requests.is_empty());
            // An asynchronous provider rejection must surface instead of silently
            // consuming an already acknowledged queued prompt.
            broker.agents.get_mut("queue-agent").unwrap().summary.state =
                super::AgentState::Running;
            broker
                .send_agent_input(
                    super::RequestId::Integer(44),
                    fixture["params"].clone(),
                    super::InputKind::Prompt,
                )
                .await;
            broker.dispatch_queued_prompt("queue-agent");
            let super::AgentCommand::Prompt { request_id, .. } = received.recv().await.unwrap()
            else {
                panic!("expected queued prompt");
            };
            broker.handle_runtime_event(super::RuntimeEvent::RequestFailed {
                request_id,
                agent_id: "queue-agent".to_owned(),
                code: -32_013,
                message: "fixture rejection".to_owned(),
                fail_agent: false,
            });
            assert_eq!(
                broker.agents["queue-agent"].summary.state,
                super::AgentState::Disconnected
            );
            assert!(broker.queued_runtime_requests.is_empty());
            assert!(broker.agents["queue-agent"].queued_prompts.is_empty());
            let mut saw_error = false;
            while let Ok(response) = responses.try_recv() {
                saw_error |= response["params"]["type"] == "broker.error";
            }
            assert!(
                saw_error,
                "queued provider rejection is visible to the client"
            );
        }
    }

    #[tokio::test]
    async fn resync_replays_events_created_during_the_initialize_handshake() {
        let (runtime, _runtime_rx) = mpsc::unbounded_channel();
        let mut broker = Broker::new(
            EmbeddedConfig::default().with_replay_capacity(2),
            BrokerMode::Durable,
            runtime,
            None,
            Vec::new(),
            None,
        );
        let (output, mut messages) = mpsc::unbounded_channel();
        broker.connect(1, output);
        for kind in ["one", "two", "three"] {
            broker.replay.push(EventEnvelope::new(
                "2026-09-02T00:00:00Z".to_owned(),
                "agent-1".to_owned(),
                Provider::Codex,
                kind.to_owned(),
                json!({}),
                json!({}),
            ));
        }

        broker
            .handle_client_frame(json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocol_version": 1,
                    "client": { "name": "resync-test", "version": "0.1.0" },
                    "last_sequence": 0,
                },
            }))
            .await
            .expect("initialize frame");
        let initialized = messages.recv().await.expect("initialize response");
        assert_eq!(initialized["result"]["replay"]["resync_required"], true);
        assert_eq!(initialized["result"]["replay"]["latest"], 3);

        broker.handle_provider_event(EventEnvelope::new(
            "2026-09-02T00:00:01Z".to_owned(),
            "agent-1".to_owned(),
            Provider::Codex,
            "during-handshake".to_owned(),
            json!({}),
            json!({}),
        ));
        assert!(
            messages.try_recv().is_err(),
            "provider events must wait for initialized"
        );

        broker
            .handle_client_frame(json!({
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": {},
            }))
            .await
            .expect("initialized frame");
        let replayed = messages.recv().await.expect("event after resync baseline");
        assert_eq!(replayed["method"], "agent/event");
        assert_eq!(replayed["params"]["sequence"], 4);
        assert_eq!(replayed["params"]["type"], "during-handshake");
        assert_eq!(
            messages.recv().await.expect("current broker state")["method"],
            "broker/state"
        );
    }
}
