//! Provider tasks owned by the embedded or durable broker.

use std::collections::{HashMap, HashSet};
use std::env;
use std::future::pending;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use uuid::Uuid;

use crate::codex::{
    CodexAppServer, CodexError, CommandSpec, ProviderEvent, active_thread_ids,
    default_thread_lock_directory, normalize_event, runtime_identity as codex_runtime_identity,
    thread_id, turn_id,
};
use crate::human::{
    HumanRequestKind, claude_approval_response, claude_question_response, claude_request,
    codex_approval_response, codex_question_response, codex_request, resolved_event,
};
use crate::projection::{history, provider_models, provider_sessions, render_input};
use crate::protocol::{EventEnvelope, Provider, ProviderOptions, ProviderRuntime, RequestId};
use crate::worker::{
    ClaudeWorker, WorkerCommandSpec, WorkerError, WorkerInbound,
    runtime_identity as claude_runtime_identity,
};

const PROVIDER_ERROR_CODE: i64 = -32_020;
const INVALID_STATE_CODE: i64 = -32_021;
const DEFAULT_CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Clone, Debug)]
pub(crate) enum SessionLaunch {
    Start,
    Resume(String),
    Fork(String),
}

#[derive(Debug)]
pub(crate) enum AgentCommand {
    Prompt {
        request_id: RequestId,
        text: String,
        attachments: Vec<Value>,
        provider_options: ProviderOptions,
    },
    Steer {
        request_id: RequestId,
        text: String,
        attachments: Vec<Value>,
    },
    Interrupt {
        request_id: RequestId,
    },
    History {
        request_id: RequestId,
        cursor: Option<String>,
        limit: Option<u32>,
    },
    Approval {
        request_id: RequestId,
        action_id: String,
        decision: String,
        updated_input: Option<Value>,
        message: Option<String>,
    },
    Question {
        request_id: RequestId,
        action_id: String,
        decision: String,
        answers: Map<String, Value>,
        message: Option<String>,
    },
    ClientDisconnected,
    Shutdown,
}

#[derive(Debug)]
pub(crate) enum RuntimeEvent {
    Started {
        request_id: RequestId,
        agent_id: String,
        provider_session_id: String,
        runtime: ProviderRuntime,
    },
    Response {
        request_id: RequestId,
        result: Value,
    },
    RequestFailed {
        request_id: RequestId,
        agent_id: String,
        code: i64,
        message: String,
        fail_agent: bool,
    },
    ProviderEvent(EventEnvelope),
    ProviderFailed {
        agent_id: String,
        message: &'static str,
    },
    Stopped {
        agent_id: String,
    },
}

#[derive(Clone, Debug)]
pub(crate) struct RuntimeConfig {
    pub codex: CommandSpec,
    pub codex_thread_locks: Option<PathBuf>,
    pub claude: WorkerCommandSpec,
    pub claude_setting_sources: Vec<String>,
    pub callback_timeout: Duration,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            codex: CommandSpec::default(),
            codex_thread_locks: default_thread_lock_directory(),
            claude: WorkerCommandSpec::default(),
            claude_setting_sources: Vec::new(),
            callback_timeout: DEFAULT_CALLBACK_TIMEOUT,
        }
    }
}

pub(crate) struct AgentSpawn {
    pub provider: Provider,
    pub agent_id: String,
    pub cwd: PathBuf,
    pub start_request_id: RequestId,
    pub launch: SessionLaunch,
    pub provider_options: ProviderOptions,
}

pub(crate) fn spawn_agent(
    spawn: AgentSpawn,
    config: RuntimeConfig,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) -> (mpsc::Sender<AgentCommand>, JoinHandle<()>) {
    let AgentSpawn {
        provider,
        agent_id,
        cwd,
        start_request_id,
        launch,
        provider_options,
    } = spawn;
    let (commands_tx, commands_rx) = mpsc::channel(32);
    let handle = match provider {
        Provider::Codex => tokio::spawn(run_codex(
            agent_id,
            cwd,
            start_request_id,
            launch,
            provider_options,
            config.codex,
            config.callback_timeout,
            commands_rx,
            events,
        )),
        Provider::Claude => tokio::spawn(run_claude(
            agent_id,
            cwd,
            start_request_id,
            launch,
            provider_options,
            config.claude,
            config.claude_setting_sources,
            config.callback_timeout,
            commands_rx,
            events,
        )),
    };
    (commands_tx, handle)
}

pub(crate) async fn discover_sessions(
    provider: Provider,
    cwd: Option<&Path>,
    cursor: Option<&str>,
    limit: u32,
    active_only: bool,
    config: &RuntimeConfig,
) -> Result<Value, &'static str> {
    let fallback_cwd = cwd.map(Path::to_path_buf).or_else(|| {
        env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
    });
    match provider {
        Provider::Codex => {
            let mut server = CodexAppServer::spawn(&config.codex)
                .map_err(|_| "Codex App Server could not be started")?;
            let initialized = server.initialize().await;
            if initialized
                .as_ref()
                .ok()
                .and_then(|value| codex_runtime_identity(value, &config.codex).ok())
                .is_none()
            {
                let _ = server.shutdown().await;
                return Err("Codex App Server initialization failed");
            }
            let outcome = match cwd {
                Some(cwd) => server.list_threads_for_directory(cwd, cursor, limit).await,
                None => server.list_threads(cursor, limit).await,
            }
            .map_err(|_| "Codex session discovery failed");
            let _ = server.shutdown().await;
            let (active, activity_available) =
                active_thread_ids(config.codex_thread_locks.as_deref());
            outcome.map(|outcome| {
                provider_sessions(
                    provider,
                    &outcome.result,
                    &active,
                    activity_available,
                    active_only,
                    fallback_cwd.as_deref(),
                )
            })
        }
        Provider::Claude => {
            let mut worker = ClaudeWorker::spawn(&config.claude)
                .map_err(|_| "Claude worker could not be started")?;
            if worker.initialize().await.is_err() {
                let _ = worker.shutdown().await;
                return Err("Claude worker initialization failed");
            }
            let outcome = worker
                .request(
                    "session/list",
                    json!({
                        "directory": cwd,
                        "limit": limit,
                        "offset": cursor.and_then(|cursor| cursor.parse::<u64>().ok()).unwrap_or(0),
                        "active_only": active_only,
                    }),
                )
                .await
                .map_err(|_| "Claude session discovery failed");
            let _ = worker.shutdown().await;
            outcome.map(|outcome| {
                let activity_available = outcome.result["activity_available"]
                    .as_bool()
                    .unwrap_or(false);
                provider_sessions(
                    provider,
                    &outcome.result,
                    &HashSet::new(),
                    activity_available,
                    active_only,
                    fallback_cwd.as_deref(),
                )
            })
        }
    }
}

pub(crate) async fn discover_models(
    provider: Provider,
    config: &RuntimeConfig,
) -> Result<Value, &'static str> {
    match provider {
        Provider::Codex => {
            let mut server = CodexAppServer::spawn(&config.codex)
                .map_err(|_| "Codex App Server could not be started")?;
            if server
                .initialize()
                .await
                .ok()
                .and_then(|value| codex_runtime_identity(&value, &config.codex).ok())
                .is_none()
            {
                let _ = server.shutdown().await;
                return Err("Codex App Server initialization failed");
            }
            let mut data = Vec::new();
            let mut cursor = None::<String>;
            for _ in 0..10 {
                let outcome = server
                    .list_models(cursor.as_deref(), 100)
                    .await
                    .map_err(|_| "Codex model discovery failed")?;
                data.extend(
                    outcome
                        .result
                        .get("data")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .cloned(),
                );
                cursor = outcome
                    .result
                    .get("nextCursor")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                if cursor.is_none() || data.len() >= 1_000 {
                    break;
                }
            }
            let _ = server.shutdown().await;
            Ok(provider_models(provider, &json!({ "data": data })))
        }
        Provider::Claude => Ok(provider_models(
            provider,
            &json!({
                "data": [
                    {
                        "model": "fable",
                        "displayName": "Fable",
                        "description": "Latest Claude Fable model alias"
                    },
                    {
                        "model": "opus",
                        "displayName": "Opus",
                        "description": "Latest Claude Opus model alias"
                    },
                    {
                        "model": "sonnet",
                        "displayName": "Sonnet",
                        "description": "Latest Claude Sonnet model alias"
                    },
                    {
                        "model": "haiku",
                        "displayName": "Haiku",
                        "description": "Latest Claude Haiku model alias"
                    }
                ]
            }),
        )),
    }
}

pub(crate) async fn delete_provider_session(
    provider: Provider,
    provider_session_id: &str,
    cwd: &Path,
    config: &RuntimeConfig,
) -> Result<(), &'static str> {
    match provider {
        Provider::Codex => {
            let (active, activity_available) =
                active_thread_ids(config.codex_thread_locks.as_deref());
            if !activity_available {
                return Err("Codex session activity could not be verified");
            }
            if active.contains(provider_session_id) {
                return Err("An active Codex session cannot be deleted");
            }
            let mut server = CodexAppServer::spawn(&config.codex)
                .map_err(|_| "Codex App Server could not be started")?;
            if server
                .initialize()
                .await
                .ok()
                .and_then(|value| codex_runtime_identity(&value, &config.codex).ok())
                .is_none()
            {
                let _ = server.shutdown().await;
                return Err("Codex App Server initialization failed");
            }
            let listed = server.list_threads_for_directory(cwd, None, 1_000).await;
            let found = listed.is_ok_and(|outcome| {
                outcome.result["data"].as_array().is_some_and(|sessions| {
                    sessions
                        .iter()
                        .any(|session| session["id"].as_str() == Some(provider_session_id))
                })
            });
            if !found {
                let _ = server.shutdown().await;
                return Err("Codex session was not found in the requested directory");
            }
            let deleted = server.delete_thread(provider_session_id).await.is_ok();
            let _ = server.shutdown().await;
            if deleted {
                Ok(())
            } else {
                Err("Codex session deletion failed")
            }
        }
        Provider::Claude => {
            let mut worker = ClaudeWorker::spawn(&config.claude)
                .map_err(|_| "Claude worker could not be started")?;
            if worker.initialize().await.is_err() {
                let _ = worker.shutdown().await;
                return Err("Claude worker initialization failed");
            }
            let deleted = worker
                .request(
                    "session/delete",
                    json!({
                        "session_id": provider_session_id,
                        "directory": cwd,
                    }),
                )
                .await
                .is_ok();
            let _ = worker.shutdown().await;
            if deleted {
                Ok(())
            } else {
                Err("Claude session deletion failed or the session is active")
            }
        }
    }
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
async fn run_codex(
    agent_id: String,
    cwd: PathBuf,
    start_request_id: RequestId,
    launch: SessionLaunch,
    provider_options: ProviderOptions,
    spec: CommandSpec,
    callback_timeout: Duration,
    mut commands: mpsc::Receiver<AgentCommand>,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Ok(mut server) = CodexAppServer::spawn(&spec) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex App Server could not be started",
        );
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Ok(initialized) = server.initialize().await else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex App Server initialization failed",
        );
        let _ = server.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Ok(runtime) = codex_runtime_identity(&initialized, &spec) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex App Server is outside the supported compatibility profile",
        );
        let _ = server.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let started = match &launch {
        SessionLaunch::Start => {
            server
                .start_thread(&cwd, provider_options.model.as_deref())
                .await
        }
        SessionLaunch::Resume(session_id) => {
            server
                .resume_thread(session_id, &cwd, provider_options.model.as_deref())
                .await
        }
        SessionLaunch::Fork(session_id) => {
            server
                .fork_thread(session_id, &cwd, provider_options.model.as_deref())
                .await
        }
    };
    let Ok(started) = started else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex session open failed",
        );
        let _ = server.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Some(provider_session_id) = thread_id(&started.result).map(str::to_owned) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex session open omitted its identity",
        );
        let _ = server.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    if events
        .send(RuntimeEvent::Started {
            request_id: start_request_id,
            agent_id: agent_id.clone(),
            provider_session_id: provider_session_id.clone(),
            runtime,
        })
        .is_err()
    {
        let _ = server.shutdown().await;
        return;
    }
    let mut pending_requests: HashMap<String, PendingCodexRequest> = HashMap::new();
    if publish_codex_events(
        &mut server,
        &agent_id,
        started.events,
        &mut pending_requests,
        callback_timeout,
        &events,
    )
    .await
    .is_err()
    {
        provider_failed(&events, &agent_id, "Codex startup events were invalid");
        let _ = server.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    }

    let mut active_turn_id: Option<String> = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    AgentCommand::Prompt {
                        request_id,
                        text,
                        attachments,
                        provider_options,
                    } => {
                        if active_turn_id.is_some() {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "agent already has an active turn",
                            );
                            continue;
                        }
                        let Ok(rendered) = render_input(&text, &attachments) else {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "editor context could not be encoded",
                            );
                            continue;
                        };
                        match server
                            .start_turn(
                                &provider_session_id,
                                &rendered,
                                provider_options.model.as_deref(),
                                provider_options.effort.as_deref(),
                            )
                            .await
                        {
                            Ok(outcome) => {
                                let Some(new_turn_id) = turn_id(&outcome.result).map(str::to_owned) else {
                                    request_failed(
                                        &events,
                                        request_id,
                                        &agent_id,
                                        PROVIDER_ERROR_CODE,
                                        "Codex turn creation omitted its identity",
                                    );
                                    continue;
                                };
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true, "turn_id": new_turn_id }),
                                });
                                active_turn_id = Some(new_turn_id);
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex turn events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex rejected the prompt",
                            ),
                        }
                    }
                    AgentCommand::Steer { request_id, text, attachments } => {
                        let Some(turn_id) = active_turn_id.as_deref() else {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "agent has no active turn to steer",
                            );
                            continue;
                        };
                        let Ok(rendered) = render_input(&text, &attachments) else {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "editor context could not be encoded",
                            );
                            continue;
                        };
                        match server.steer(&provider_session_id, turn_id, &rendered).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true }),
                                });
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex steer events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex rejected the steering input",
                            ),
                        }
                    }
                    AgentCommand::Interrupt { request_id } => {
                        if deny_all_codex_requests(
                            &mut server,
                            &agent_id,
                            &mut pending_requests,
                            "interrupt",
                            &events,
                        )
                        .await
                        .is_err()
                        {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex pending request cancellation failed",
                            );
                            continue;
                        }
                        let Some(turn_id) = active_turn_id.as_deref() else {
                            let _ = events.send(RuntimeEvent::Response {
                                request_id,
                                result: json!({ "interrupted": false, "reason": "no_active_turn" }),
                            });
                            continue;
                        };
                        match server.interrupt_with_events(&provider_session_id, turn_id).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "interrupted": true }),
                                });
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex interrupt events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex interrupt failed",
                            ),
                        }
                    }
                    AgentCommand::History { request_id, cursor: _, limit: _ } => {
                        match server.read_thread(&provider_session_id).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: history(Provider::Codex, &outcome.result),
                                });
                            }
                            Err(_) => request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "Codex history request failed",
                            ),
                        }
                    }
                    AgentCommand::Approval {
                        request_id,
                        action_id,
                        decision,
                        updated_input: _,
                        message,
                    } => {
                        respond_codex_approval(
                            &mut server,
                            &agent_id,
                            request_id,
                            &action_id,
                            &decision,
                            message.as_deref(),
                            &mut pending_requests,
                            &events,
                        )
                        .await;
                    }
                    AgentCommand::Question {
                        request_id,
                        action_id,
                        decision,
                        answers,
                        message: _,
                    } => {
                        respond_codex_question(
                            &mut server,
                            &agent_id,
                            request_id,
                            &action_id,
                            &decision,
                            &answers,
                            &mut pending_requests,
                            &events,
                        )
                        .await;
                    }
                    AgentCommand::ClientDisconnected => {
                        if deny_all_codex_requests(
                            &mut server,
                            &agent_id,
                            &mut pending_requests,
                            "client_disconnect",
                            &events,
                        )
                        .await
                        .is_err()
                        {
                            provider_failed(
                                &events,
                                &agent_id,
                                "Codex client disconnect handling failed",
                            );
                            break;
                        }
                    }
                    AgentCommand::Shutdown => {
                        let _ = deny_all_codex_requests(
                            &mut server,
                            &agent_id,
                            &mut pending_requests,
                            "shutdown",
                            &events,
                        )
                        .await;
                        break;
                    }
                }
            }
            provider_event = server.next_event(), if active_turn_id.is_some() => {
                if let Ok(provider_event) = provider_event {
                    match publish_codex_event(
                        &mut server,
                        &agent_id,
                        provider_event,
                        &mut pending_requests,
                        callback_timeout,
                        &events,
                    ).await {
                        Ok(true) => active_turn_id = None,
                        Ok(false) => {}
                        Err(_) => {
                            provider_failed(&events, &agent_id, "Codex event stream failed");
                            break;
                        }
                    }
                } else {
                    provider_failed(&events, &agent_id, "Codex event stream disconnected");
                    break;
                }
            }
            () = wait_for_deadline(next_codex_deadline(&pending_requests)), if !pending_requests.is_empty() => {
                if expire_codex_requests(
                    &mut server,
                    &agent_id,
                    &mut pending_requests,
                    &events,
                )
                .await
                .is_err()
                {
                    provider_failed(&events, &agent_id, "Codex callback timeout handling failed");
                    break;
                }
            }
        }
    }

    let _ = deny_all_codex_requests(
        &mut server,
        &agent_id,
        &mut pending_requests,
        "provider_exit",
        &events,
    )
    .await;
    let _ = server.shutdown().await;
    let _ = events.send(RuntimeEvent::Stopped { agent_id });
}

async fn publish_codex_events(
    server: &mut CodexAppServer,
    agent_id: &str,
    provider_events: Vec<ProviderEvent>,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    callback_timeout: Duration,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, CodexError> {
    let mut terminal = false;
    for provider_event in provider_events {
        terminal |= publish_codex_event(
            server,
            agent_id,
            provider_event,
            pending_requests,
            callback_timeout,
            events,
        )
        .await?;
    }
    Ok(terminal)
}

async fn publish_codex_event(
    server: &mut CodexAppServer,
    agent_id: &str,
    mut provider_event: ProviderEvent,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    callback_timeout: Duration,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, CodexError> {
    let terminal = matches!(provider_event.method.as_str(), "turn/completed" | "error");
    if provider_event.response_required {
        let action_id = Uuid::new_v4().to_string();
        if let Some(request) = codex_request(agent_id, action_id, &provider_event) {
            let pending = PendingCodexRequest {
                kind: request.kind,
                event: provider_event,
                deadline: Instant::now() + callback_timeout,
            };
            pending_requests.insert(request.id, pending);
            let _ = events.send(RuntimeEvent::ProviderEvent(request.envelope));
            return Ok(false);
        }
        server.deny_server_request(&mut provider_event).await?;
    }
    let normalized = normalize_event(agent_id, &provider_event)?;
    let _ = events.send(RuntimeEvent::ProviderEvent(normalized));
    Ok(terminal)
}

struct PendingCodexRequest {
    kind: HumanRequestKind,
    event: ProviderEvent,
    deadline: Instant,
}

#[allow(clippy::too_many_arguments)]
async fn respond_codex_approval(
    server: &mut CodexAppServer,
    agent_id: &str,
    request_id: RequestId,
    action_id: &str,
    decision: &str,
    message: Option<&str>,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Some(pending) = pending_requests.get_mut(action_id) else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "approval request is no longer pending",
        );
        return;
    };
    if pending.kind != HumanRequestKind::Approval {
        request_rejected(
            events,
            request_id,
            agent_id,
            "pending request is not an approval",
        );
        return;
    }
    let result = match codex_approval_response(&pending.event, decision, message) {
        Ok(result) => result,
        Err(message) => {
            request_rejected(events, request_id, agent_id, message);
            return;
        }
    };
    if server
        .respond_server_request(&mut pending.event, result)
        .await
        .is_err()
    {
        request_failed(
            events,
            request_id,
            agent_id,
            PROVIDER_ERROR_CODE,
            "Codex approval response failed",
        );
        return;
    }
    pending_requests.remove(action_id);
    let _ = events.send(RuntimeEvent::Response {
        request_id,
        result: json!({ "resolved": true, "id": action_id, "decision": decision }),
    });
    let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
        agent_id,
        Provider::Codex,
        HumanRequestKind::Approval,
        action_id,
        decision,
        None,
    )));
}

#[allow(clippy::too_many_arguments)]
async fn respond_codex_question(
    server: &mut CodexAppServer,
    agent_id: &str,
    request_id: RequestId,
    action_id: &str,
    decision: &str,
    answers: &Map<String, Value>,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Some(pending) = pending_requests.get_mut(action_id) else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "question request is no longer pending",
        );
        return;
    };
    if pending.kind != HumanRequestKind::Question {
        request_rejected(
            events,
            request_id,
            agent_id,
            "pending request is not a question",
        );
        return;
    }
    let result = match codex_question_response(&pending.event, decision, answers) {
        Ok(result) => result,
        Err(message) => {
            request_rejected(events, request_id, agent_id, message);
            return;
        }
    };
    if server
        .respond_server_request(&mut pending.event, result)
        .await
        .is_err()
    {
        request_failed(
            events,
            request_id,
            agent_id,
            PROVIDER_ERROR_CODE,
            "Codex question response failed",
        );
        return;
    }
    pending_requests.remove(action_id);
    let _ = events.send(RuntimeEvent::Response {
        request_id,
        result: json!({ "resolved": true, "id": action_id, "decision": decision }),
    });
    let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
        agent_id,
        Provider::Codex,
        HumanRequestKind::Question,
        action_id,
        decision,
        None,
    )));
}

async fn deny_all_codex_requests(
    server: &mut CodexAppServer,
    agent_id: &str,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    reason: &'static str,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<(), CodexError> {
    let mut failure = None;
    let action_ids = pending_requests.keys().cloned().collect::<Vec<_>>();
    for action_id in action_ids {
        let Some(mut pending_request) = pending_requests.remove(&action_id) else {
            continue;
        };
        if let Err(error) = server.deny_server_request(&mut pending_request.event).await {
            failure.get_or_insert(error);
        }
        let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
            agent_id,
            Provider::Codex,
            pending_request.kind,
            &action_id,
            "deny",
            Some(reason),
        )));
    }
    failure.map_or(Ok(()), Err)
}

async fn expire_codex_requests(
    server: &mut CodexAppServer,
    agent_id: &str,
    pending_requests: &mut HashMap<String, PendingCodexRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<(), CodexError> {
    let now = Instant::now();
    let mut failure = None;
    let expired = pending_requests
        .iter()
        .filter(|(_, request)| request.deadline <= now)
        .map(|(action_id, _)| action_id.clone())
        .collect::<Vec<_>>();
    for action_id in expired {
        let Some(mut pending_request) = pending_requests.remove(&action_id) else {
            continue;
        };
        if let Err(error) = server.deny_server_request(&mut pending_request.event).await {
            failure.get_or_insert(error);
        }
        let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
            agent_id,
            Provider::Codex,
            pending_request.kind,
            &action_id,
            "deny",
            Some("timeout"),
        )));
    }
    failure.map_or(Ok(()), Err)
}

fn next_codex_deadline(pending_requests: &HashMap<String, PendingCodexRequest>) -> Option<Instant> {
    pending_requests
        .values()
        .map(|request| request.deadline)
        .min()
}

async fn wait_for_deadline(deadline: Option<Instant>) {
    if let Some(deadline) = deadline {
        tokio::time::sleep_until(deadline).await;
    } else {
        pending::<()>().await;
    }
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
async fn run_claude(
    agent_id: String,
    cwd: PathBuf,
    start_request_id: RequestId,
    launch: SessionLaunch,
    provider_options: ProviderOptions,
    spec: WorkerCommandSpec,
    setting_sources: Vec<String>,
    callback_timeout: Duration,
    mut commands: mpsc::Receiver<AgentCommand>,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Ok(mut worker) = ClaudeWorker::spawn(&spec) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude worker could not be started",
        );
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Ok(initialized) = worker.initialize().await else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude worker initialization failed",
        );
        let _ = worker.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Ok(runtime) = claude_runtime_identity(&initialized) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude worker is outside the supported compatibility profile",
        );
        let _ = worker.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let (open_method, open_params) = match &launch {
        SessionLaunch::Start => (
            "session/start",
            json!({
                "agent_id": agent_id,
                "cwd": cwd,
                "model": provider_options.model,
                "effort": provider_options.effort,
                "setting_sources": setting_sources,
            }),
        ),
        SessionLaunch::Resume(session_id) => (
            "session/resume",
            json!({
                "agent_id": agent_id,
                "cwd": cwd,
                "session_id": session_id,
                "model": provider_options.model,
                "effort": provider_options.effort,
                "setting_sources": setting_sources,
            }),
        ),
        SessionLaunch::Fork(session_id) => (
            "session/fork",
            json!({
                "agent_id": agent_id,
                "cwd": cwd,
                "session_id": session_id,
                "model": provider_options.model,
                "effort": provider_options.effort,
                "setting_sources": setting_sources,
            }),
        ),
    };
    let Ok(started) = worker.request(open_method, open_params).await else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude session open failed",
        );
        let _ = worker.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    let Some(provider_session_id) = started
        .result
        .get("provider_session_id")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude session open omitted its identity",
        );
        let _ = worker.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    };
    if events
        .send(RuntimeEvent::Started {
            request_id: start_request_id,
            agent_id: agent_id.clone(),
            provider_session_id: provider_session_id.clone(),
            runtime,
        })
        .is_err()
    {
        let _ = worker.shutdown().await;
        return;
    }
    let mut pending_requests: HashMap<String, PendingWorkerRequest> = HashMap::new();
    if publish_worker_inbound(
        &mut worker,
        &agent_id,
        started.inbound,
        &mut pending_requests,
        callback_timeout,
        &events,
    )
    .await
    .is_err()
    {
        provider_failed(&events, &agent_id, "Claude startup events were invalid");
        let _ = worker.shutdown().await;
        runtime_stopped(&events, &agent_id);
        return;
    }

    let mut active_turn_id: Option<String> = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    AgentCommand::Prompt {
                        request_id,
                        text,
                        attachments,
                        provider_options,
                    } => {
                        if active_turn_id.is_some() {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "agent already has an active turn",
                            );
                            continue;
                        }
                        let Ok(rendered) = render_input(&text, &attachments) else {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "editor context could not be encoded",
                            );
                            continue;
                        };
                        match worker
                            .request(
                                "turn/prompt",
                                json!({
                                    "agent_id": agent_id,
                                    "text": rendered,
                                    "model": provider_options.model,
                                    "effort": provider_options.effort,
                                }),
                            )
                            .await
                        {
                            Ok(outcome) => {
                                let new_turn_id = Uuid::new_v4().to_string();
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true, "turn_id": new_turn_id }),
                                });
                                active_turn_id = Some(new_turn_id.clone());
                                let _ = events.send(RuntimeEvent::ProviderEvent(synthetic_claude_event(
                                    &agent_id,
                                    "turn.started",
                                    json!({ "turn": { "id": new_turn_id } }),
                                    "turn/prompt",
                                )));
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude turn events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude rejected the prompt",
                            ),
                        }
                    }
                    AgentCommand::Steer { request_id, text, attachments } => {
                        if active_turn_id.is_none() {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "agent has no active turn to steer",
                            );
                            continue;
                        }
                        let Ok(rendered) = render_input(&text, &attachments) else {
                            request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "editor context could not be encoded",
                            );
                            continue;
                        };
                        match worker.request("turn/steer", json!({ "agent_id": agent_id, "text": rendered })).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true }),
                                });
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude steer events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude rejected the steering input",
                            ),
                        }
                    }
                    AgentCommand::Interrupt { request_id } => {
                        if deny_all_worker_requests(
                            &mut worker,
                            &agent_id,
                            &mut pending_requests,
                            "interrupt",
                            &events,
                        )
                        .await
                        .is_err()
                        {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude pending request cancellation failed",
                            );
                            continue;
                        }
                        if active_turn_id.is_none() {
                            let _ = events.send(RuntimeEvent::Response {
                                request_id,
                                result: json!({ "interrupted": false, "reason": "no_active_turn" }),
                            });
                            continue;
                        }
                        match worker.request("turn/interrupt", json!({ "agent_id": agent_id })).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: outcome.result,
                                });
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &mut pending_requests,
                                    callback_timeout,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude interrupt events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude interrupt failed",
                            ),
                        }
                    }
                    AgentCommand::History { request_id, cursor, limit } => {
                        let offset = cursor.and_then(|cursor| cursor.parse::<u64>().ok()).unwrap_or(0);
                        match worker.request(
                            "session/history",
                            json!({
                                "session_id": provider_session_id,
                                "directory": cwd,
                                "limit": limit,
                                "offset": offset,
                            }),
                        ).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: history(Provider::Claude, &outcome.result),
                                });
                            }
                            Err(_) => request_rejected(
                                &events,
                                request_id,
                                &agent_id,
                                "Claude history request failed",
                            ),
                        }
                    }
                    AgentCommand::Approval {
                        request_id,
                        action_id,
                        decision,
                        updated_input,
                        message,
                    } => {
                        respond_worker_approval(
                            &mut worker,
                            &agent_id,
                            request_id,
                            &action_id,
                            &decision,
                            updated_input,
                            message.as_deref(),
                            &mut pending_requests,
                            &events,
                        )
                        .await;
                    }
                    AgentCommand::Question {
                        request_id,
                        action_id,
                        decision,
                        answers,
                        message,
                    } => {
                        respond_worker_question(
                            &mut worker,
                            &agent_id,
                            request_id,
                            &action_id,
                            &decision,
                            &answers,
                            message.as_deref(),
                            &mut pending_requests,
                            &events,
                        )
                        .await;
                    }
                    AgentCommand::ClientDisconnected => {
                        if deny_all_worker_requests(
                            &mut worker,
                            &agent_id,
                            &mut pending_requests,
                            "client_disconnect",
                            &events,
                        )
                        .await
                        .is_err()
                        {
                            provider_failed(
                                &events,
                                &agent_id,
                                "Claude client disconnect handling failed",
                            );
                            break;
                        }
                    }
                    AgentCommand::Shutdown => {
                        let _ = deny_all_worker_requests(
                            &mut worker,
                            &agent_id,
                            &mut pending_requests,
                            "shutdown",
                            &events,
                        )
                        .await;
                        break;
                    }
                }
            }
            inbound = worker.next_inbound(), if active_turn_id.is_some() => {
                if let Ok(inbound) = inbound {
                    match publish_worker_event(
                        &mut worker,
                        &agent_id,
                        inbound,
                        &mut pending_requests,
                        callback_timeout,
                        &events,
                    ).await {
                        Ok(true) => active_turn_id = None,
                        Ok(false) => {}
                        Err(_) => {
                            provider_failed(&events, &agent_id, "Claude event stream failed");
                            break;
                        }
                    }
                } else {
                    provider_failed(&events, &agent_id, "Claude event stream disconnected");
                    break;
                }
            }
            () = wait_for_deadline(next_worker_deadline(&pending_requests)), if !pending_requests.is_empty() => {
                if expire_worker_requests(
                    &mut worker,
                    &agent_id,
                    &mut pending_requests,
                    &events,
                )
                .await
                .is_err()
                {
                    provider_failed(&events, &agent_id, "Claude callback timeout handling failed");
                    break;
                }
            }
        }
    }

    let _ = deny_all_worker_requests(
        &mut worker,
        &agent_id,
        &mut pending_requests,
        "provider_exit",
        &events,
    )
    .await;
    let _ = worker.shutdown().await;
    let _ = events.send(RuntimeEvent::Stopped { agent_id });
}

async fn publish_worker_inbound(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    inbound: Vec<WorkerInbound>,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    callback_timeout: Duration,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, WorkerError> {
    let mut terminal = false;
    for event in inbound {
        terminal |= publish_worker_event(
            worker,
            agent_id,
            event,
            pending_requests,
            callback_timeout,
            events,
        )
        .await?;
    }
    Ok(terminal)
}

async fn publish_worker_event(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    inbound: WorkerInbound,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    callback_timeout: Duration,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, WorkerError> {
    if inbound.is_callback() {
        let action_id = Uuid::new_v4().to_string();
        if let Some(request) = claude_request(agent_id, action_id, &inbound) {
            let pending = PendingWorkerRequest {
                kind: request.kind,
                inbound,
                deadline: Instant::now() + callback_timeout,
            };
            pending_requests.insert(request.id, pending);
            let _ = events.send(RuntimeEvent::ProviderEvent(request.envelope));
            return Ok(false);
        }
        if let Some(callback_id) = inbound.id.as_ref() {
            worker
                .deny_callback(callback_id, "Unsupported callback denied by Agent Manager")
                .await?;
        }
    }
    let normalized_type = normalized_worker_event_type(&inbound);
    let terminal = matches!(normalized_type, "turn.completed" | "turn.failed");
    let payload = if inbound.method == "session/event" {
        inbound
            .params
            .get("payload")
            .cloned()
            .unwrap_or_else(|| json!({}))
    } else {
        inbound.params.clone()
    };
    let provider_event = json!({
        "kind": if inbound.id.is_some() { "request" } else { "notification" },
        "request_id": inbound.id,
        "response_required": false,
        "method": inbound.method,
        "params": inbound.params,
    });
    let envelope = EventEnvelope::new(
        timestamp(),
        agent_id.to_owned(),
        Provider::Claude,
        normalized_type.to_owned(),
        payload,
        provider_event,
    );
    let _ = events.send(RuntimeEvent::ProviderEvent(envelope));
    Ok(terminal)
}

struct PendingWorkerRequest {
    kind: HumanRequestKind,
    inbound: WorkerInbound,
    deadline: Instant,
}

#[allow(clippy::too_many_arguments)]
async fn respond_worker_approval(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    request_id: RequestId,
    action_id: &str,
    decision: &str,
    updated_input: Option<Value>,
    message: Option<&str>,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Some(pending_request) = pending_requests.get(action_id) else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "approval request is no longer pending",
        );
        return;
    };
    if pending_request.kind != HumanRequestKind::Approval {
        request_rejected(
            events,
            request_id,
            agent_id,
            "pending request is not an approval",
        );
        return;
    }
    let result = match claude_approval_response(decision, updated_input, message) {
        Ok(result) => result,
        Err(message) => {
            request_rejected(events, request_id, agent_id, message);
            return;
        }
    };
    let Some(callback_id) = pending_request.inbound.id.as_ref() else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "provider callback omitted its identity",
        );
        return;
    };
    if worker.respond_callback(callback_id, result).await.is_err() {
        request_failed(
            events,
            request_id,
            agent_id,
            PROVIDER_ERROR_CODE,
            "Claude approval response failed",
        );
        return;
    }
    pending_requests.remove(action_id);
    let _ = events.send(RuntimeEvent::Response {
        request_id,
        result: json!({ "resolved": true, "id": action_id, "decision": decision }),
    });
    let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
        agent_id,
        Provider::Claude,
        HumanRequestKind::Approval,
        action_id,
        decision,
        None,
    )));
}

#[allow(clippy::too_many_arguments)]
async fn respond_worker_question(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    request_id: RequestId,
    action_id: &str,
    decision: &str,
    answers: &Map<String, Value>,
    message: Option<&str>,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Some(pending_request) = pending_requests.get(action_id) else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "question request is no longer pending",
        );
        return;
    };
    if pending_request.kind != HumanRequestKind::Question {
        request_rejected(
            events,
            request_id,
            agent_id,
            "pending request is not a question",
        );
        return;
    }
    let result = match claude_question_response(decision, answers, message) {
        Ok(result) => result,
        Err(message) => {
            request_rejected(events, request_id, agent_id, message);
            return;
        }
    };
    let Some(callback_id) = pending_request.inbound.id.as_ref() else {
        request_rejected(
            events,
            request_id,
            agent_id,
            "provider callback omitted its identity",
        );
        return;
    };
    if worker.respond_callback(callback_id, result).await.is_err() {
        request_failed(
            events,
            request_id,
            agent_id,
            PROVIDER_ERROR_CODE,
            "Claude question response failed",
        );
        return;
    }
    pending_requests.remove(action_id);
    let _ = events.send(RuntimeEvent::Response {
        request_id,
        result: json!({ "resolved": true, "id": action_id, "decision": decision }),
    });
    let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
        agent_id,
        Provider::Claude,
        HumanRequestKind::Question,
        action_id,
        decision,
        None,
    )));
}

async fn deny_all_worker_requests(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    reason: &'static str,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<(), WorkerError> {
    let mut failure = None;
    let action_ids = pending_requests.keys().cloned().collect::<Vec<_>>();
    for action_id in action_ids {
        let Some(pending_request) = pending_requests.remove(&action_id) else {
            continue;
        };
        if let Some(callback_id) = pending_request.inbound.id.as_ref()
            && let Err(error) = worker
                .deny_callback(callback_id, "Agent Manager closed the pending request")
                .await
        {
            failure.get_or_insert(error);
        }
        let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
            agent_id,
            Provider::Claude,
            pending_request.kind,
            &action_id,
            "deny",
            Some(reason),
        )));
    }
    failure.map_or(Ok(()), Err)
}

async fn expire_worker_requests(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    pending_requests: &mut HashMap<String, PendingWorkerRequest>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<(), WorkerError> {
    let now = Instant::now();
    let mut failure = None;
    let expired = pending_requests
        .iter()
        .filter(|(_, request)| request.deadline <= now)
        .map(|(action_id, _)| action_id.clone())
        .collect::<Vec<_>>();
    for action_id in expired {
        let Some(pending_request) = pending_requests.remove(&action_id) else {
            continue;
        };
        if let Some(callback_id) = pending_request.inbound.id.as_ref()
            && let Err(error) = worker
                .deny_callback(callback_id, "Agent Manager callback timed out")
                .await
        {
            failure.get_or_insert(error);
        }
        let _ = events.send(RuntimeEvent::ProviderEvent(resolved_event(
            agent_id,
            Provider::Claude,
            pending_request.kind,
            &action_id,
            "deny",
            Some("timeout"),
        )));
    }
    failure.map_or(Ok(()), Err)
}

fn next_worker_deadline(
    pending_requests: &HashMap<String, PendingWorkerRequest>,
) -> Option<Instant> {
    pending_requests
        .values()
        .map(|request| request.deadline)
        .min()
}

fn normalized_worker_event_type(inbound: &WorkerInbound) -> &'static str {
    match inbound.method.as_str() {
        "approval/request" => "approval.requested",
        "question/request" => "question.requested",
        "session/event" => match inbound.params["event_type"].as_str() {
            Some("message.assistant") => "message.completed",
            Some("stream.event") => "message.delta",
            Some("file.changed" | "file_change") => "file.changed",
            Some("diff.changed" | "diff") => "diff.changed",
            Some("result") if inbound.params["payload"]["is_error"] == true => "turn.failed",
            Some("result") => "turn.completed",
            Some("task.started") => "tool.started",
            Some("hook.event") if worker_event_changes_file(&inbound.params["payload"]) => {
                "file.changed"
            }
            Some("task.progress" | "hook.event") => "tool.progress",
            Some("task.notification") => "tool.completed",
            Some("rate_limit") => "usage.updated",
            Some("provider.error") => "turn.failed",
            _ => "provider.notice",
        },
        _ => "provider.notice",
    }
}

fn worker_event_changes_file(payload: &Value) -> bool {
    let tool = payload
        .get("tool_name")
        .or_else(|| payload.get("toolName"))
        .or_else(|| payload.get("tool"))
        .and_then(Value::as_str);
    matches!(tool, Some("Write" | "Edit" | "MultiEdit" | "NotebookEdit"))
}

fn synthetic_claude_event(
    agent_id: &str,
    event_type: &str,
    payload: Value,
    provider_method: &str,
) -> EventEnvelope {
    EventEnvelope::new(
        timestamp(),
        agent_id.to_owned(),
        Provider::Claude,
        event_type.to_owned(),
        payload,
        json!({ "kind": "synthetic", "method": provider_method }),
    )
}

fn timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn start_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    request_id: RequestId,
    agent_id: &str,
    message: &'static str,
) {
    request_failed(events, request_id, agent_id, PROVIDER_ERROR_CODE, message);
}

fn runtime_stopped(events: &mpsc::UnboundedSender<RuntimeEvent>, agent_id: &str) {
    let _ = events.send(RuntimeEvent::Stopped {
        agent_id: agent_id.to_owned(),
    });
}

fn request_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    request_id: RequestId,
    agent_id: &str,
    code: i64,
    message: &'static str,
) {
    let _ = events.send(RuntimeEvent::RequestFailed {
        request_id,
        agent_id: agent_id.to_owned(),
        code,
        message: message.to_owned(),
        fail_agent: true,
    });
}

fn request_rejected(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    request_id: RequestId,
    agent_id: &str,
    message: &'static str,
) {
    let _ = events.send(RuntimeEvent::RequestFailed {
        request_id,
        agent_id: agent_id.to_owned(),
        code: INVALID_STATE_CODE,
        message: message.to_owned(),
        fail_agent: false,
    });
}

fn provider_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    agent_id: &str,
    message: &'static str,
) {
    let _ = events.send(RuntimeEvent::ProviderFailed {
        agent_id: agent_id.to_owned(),
        message,
    });
}
