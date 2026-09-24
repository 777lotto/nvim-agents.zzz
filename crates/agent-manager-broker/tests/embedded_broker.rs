use std::fs;
use std::future::Future;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use agent_manager_broker::codex::CommandSpec;
use agent_manager_broker::embedded::{EmbeddedConfig, EmbeddedError, serve};
use agent_manager_broker::protocol::Provider;
use agent_manager_broker::worker::WorkerCommandSpec;
use serde_json::{Value, json};
use tokio::io::{
    AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, ReadHalf, WriteHalf, duplex, split,
};
use tokio::task::JoinHandle;
use tokio::time::timeout;

const IO_TIMEOUT: Duration = Duration::from_secs(5);

struct Harness {
    reader: BufReader<ReadHalf<DuplexStream>>,
    writer: WriteHalf<DuplexStream>,
    broker: JoinHandle<Result<(), EmbeddedError>>,
    transcript: Vec<Value>,
}

impl Harness {
    fn start() -> Self {
        Self::start_with_callback_timeout(Duration::from_secs(300))
    }

    fn start_with_callback_timeout(callback_timeout: Duration) -> Self {
        let codex = fixture_command("fake_m1_codex_app_server.py");
        let claude = fixture_command("fake_m1_claude_worker.py");
        Self::start_with_provider_commands(
            callback_timeout,
            CommandSpec {
                program: "python".to_owned(),
                args: vec![codex.to_string_lossy().into_owned()],
            },
            WorkerCommandSpec {
                program: "python".to_owned(),
                args: vec![claude.to_string_lossy().into_owned()],
            },
        )
    }

    fn start_with_provider_commands(
        callback_timeout: Duration,
        codex: CommandSpec,
        claude: WorkerCommandSpec,
    ) -> Self {
        let config = EmbeddedConfig::default()
            .with_provider_commands(codex, claude)
            .with_callback_timeout(callback_timeout);
        Self::start_with_config(config)
    }

    fn start_with_config(config: EmbeddedConfig) -> Self {
        let (client, server) = duplex(1024 * 1024);
        let (client_reader, client_writer) = split(client);
        let (server_reader, server_writer) = split(server);
        let broker = tokio::spawn(serve(BufReader::new(server_reader), server_writer, config));
        Self {
            reader: BufReader::new(client_reader),
            writer: client_writer,
            broker,
            transcript: Vec::new(),
        }
    }

    async fn send(&mut self, message: Value) {
        let mut frame = serde_json::to_vec(&message).expect("serialize client message");
        frame.push(b'\n');
        self.send_raw(&frame).await;
    }

    async fn send_raw(&mut self, frame: &[u8]) {
        self.writer.write_all(frame).await.expect("write request");
        self.writer.flush().await.expect("flush request");
    }

    async fn receive(&mut self) -> Value {
        let mut line = String::new();
        let bytes = timeout(IO_TIMEOUT, self.reader.read_line(&mut line))
            .await
            .expect("broker response timed out")
            .expect("read broker response");
        assert_ne!(bytes, 0, "broker closed its output unexpectedly");
        let message: Value = serde_json::from_str(&line).expect("broker emitted JSON");
        self.transcript.push(message.clone());
        message
    }

    async fn wait_for(&mut self, mut predicate: impl FnMut(&Value) -> bool) -> Value {
        loop {
            let message = self.receive().await;
            if predicate(&message) {
                return message;
            }
        }
    }

    async fn response(&mut self, id: i64) -> Value {
        self.wait_for(|message| message.get("id").and_then(Value::as_i64) == Some(id))
            .await
    }

    async fn event(&mut self, event_type: &str) -> Value {
        self.wait_for(|message| {
            message.get("method").and_then(Value::as_str) == Some("agent/event")
                && message["params"]["type"] == event_type
        })
        .await
    }

    async fn state(&mut self, state: &str) -> Value {
        self.wait_for(|message| {
            message.get("method").and_then(Value::as_str) == Some("broker/state")
                && message["params"]["agents"]
                    .as_array()
                    .and_then(|agents| agents.first())
                    .is_some_and(|agent| agent["state"] == state)
        })
        .await
    }

    async fn shutdown(mut self, request_id: i64) {
        self.send(request(request_id, "broker/shutdown", json!({})))
            .await;
        assert_eq!(self.response(request_id).await["result"]["shutdown"], true);
        timeout(IO_TIMEOUT, self.broker)
            .await
            .expect("broker shutdown timed out")
            .expect("broker task panicked")
            .expect("broker shutdown failed");
    }
}

struct ManagedWorkspaceFixture {
    root: PathBuf,
    lifecycle: PathBuf,
    worktree: PathBuf,
    marker: PathBuf,
}

impl ManagedWorkspaceFixture {
    fn new() -> Self {
        Self::with_claim_receipt(true)
    }

    fn without_claim_receipt() -> Self {
        Self::with_claim_receipt(false)
    }

    fn with_claim_receipt(emit_claim_receipt: bool) -> Self {
        let root = std::env::temp_dir().join(format!(
            "agent-manager-managed-workspace-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&root).expect("create managed workspace fixture root");
        let root = root
            .canonicalize()
            .expect("canonical managed workspace fixture root");
        let canonical = root.join("canonical");
        let worktree = root.join("worktrees/agent-manager/managed-task");
        fs::create_dir_all(&canonical).expect("create canonical fixture");
        run_git(&canonical, &["init", "--initial-branch=bluff"]);
        run_git(&canonical, &["config", "user.name", "Agent Manager Test"]);
        run_git(
            &canonical,
            &["config", "user.email", "agent-manager@example.invalid"],
        );
        fs::write(canonical.join("README.md"), "fixture\n").expect("write Git fixture");
        run_git(&canonical, &["add", "README.md"]);
        run_git(&canonical, &["commit", "-m", "fixture"]);
        fs::create_dir_all(worktree.parent().expect("worktree parent"))
            .expect("create worktree root");
        run_git(
            &canonical,
            &[
                "worktree",
                "add",
                "-b",
                "agent/managed-task",
                worktree.to_str().expect("UTF-8 worktree"),
            ],
        );
        run_git(
            &worktree,
            &[
                "config",
                "branch.agent/managed-task.merge",
                "refs/heads/bluff",
            ],
        );

        let marker = root.join("lifecycle-calls.txt");
        let lifecycle = root.join("fake-workspace-lifecycle.py");
        let audit = json!({
            "schema_version": 1,
            "generated_at": "2026-09-03T00:00:00Z",
            "registry": root.join("repositories.toml"),
            "repositories": [{
                "slug": "agent-manager",
                "github": "owner/agent-manager.nvimz",
                "canonical": {
                    "path": canonical,
                    "base_branch": "bluff",
                    "branch": "bluff",
                    "clean": true
                },
                "worktree_root": worktree.parent().expect("worktree root"),
                "worktrees": [{
                    "task_id": "managed-task",
                    "branch": "agent/managed-task",
                    "path": worktree,
                    "head": "fixture",
                    "upstream": null,
                    "lease_identity": ["launcher:test"],
                    "lease_keep": null,
                    "lease_transition": "claim-acquired",
                    "cleanup_candidate": false,
                    "reasons": []
                }]
            }]
        });
        let script = format!(
            "#!/usr/bin/env python3\nimport pathlib, sys\nAUDIT = {audit:?}\nEMIT_CLAIM_RECEIPT = {emit_claim_receipt}\nMARKER = pathlib.Path({marker:?})\nWORKTREE = {worktree:?}\ncommand = sys.argv[1]\nwith MARKER.open('a', encoding='utf-8') as target:\n    target.write(' '.join(sys.argv[1:]) + '\\n')\nif command == 'audit':\n    print(AUDIT)\nelif command in ('claim', 'handoff'):\n    if command == 'claim' and EMIT_CLAIM_RECEIPT:\n        print('claimed: agent-manager/managed-task: ' + WORKTREE + ' branch=agent/managed-task lease=held')\n        print('hand off with: ignored')\nelse:\n    raise SystemExit(2)\n",
            audit = serde_json::to_string(&audit).expect("encode audit"),
            emit_claim_receipt = if emit_claim_receipt { "True" } else { "False" },
            marker = marker.to_string_lossy(),
            worktree = worktree.to_string_lossy(),
        );
        fs::write(&lifecycle, script).expect("write lifecycle fixture");
        fs::set_permissions(&lifecycle, fs::Permissions::from_mode(0o700))
            .expect("make lifecycle fixture executable");
        Self {
            root,
            lifecycle,
            worktree,
            marker,
        }
    }
}

impl Drop for ManagedWorkspaceFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn run_git(cwd: &std::path::Path, arguments: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(arguments)
        .status()
        .expect("start fixture Git command");
    assert!(
        status.success(),
        "fixture Git command failed: {arguments:?}"
    );
}

fn fixture_command(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn request(id: i64, method: &str, params: Value) -> Value {
    let mut request = serde_json::Map::new();
    request.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    request.insert("id".to_owned(), json!(id));
    request.insert("method".to_owned(), Value::String(method.to_owned()));
    request.insert("params".to_owned(), params);
    Value::Object(request)
}

async fn prove_global_active_session_discovery(provider: Provider) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "active-session-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    harness
        .send(request(
            2,
            "provider/session/list",
            json!({
                "provider": provider,
                "cursor": null,
                "limit": 1000,
                "active_only": true
            }),
        ))
        .await;
    let discovered = harness.response(2).await;
    let sessions = discovered["result"]["sessions"]
        .as_array()
        .expect("active session array");
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["provider"], json!(provider));
    assert_eq!(sessions[0]["cwd"], "/tmp");
    assert_eq!(sessions[0]["active"], true);
    assert_eq!(sessions[0]["state"], "running");
    harness.shutdown(3).await;
}

#[allow(clippy::too_many_lines)]
async fn prove_embedded_flow(provider: Provider) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": {
                    "name": "agent-manager-test",
                    "title": "Agent Manager Test",
                    "version": "0.1.0"
                },
                "last_sequence": null
            }),
        ))
        .await;
    let initialized = harness.response(1).await;
    assert_eq!(initialized["result"]["protocol_version"], 1);
    assert_eq!(initialized["result"]["protocol_revision"], 1);
    assert_eq!(initialized["result"]["mode"], "embedded");
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    let empty_state = harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    assert_eq!(empty_state["params"]["agents"], json!([]));

    harness
        .send(request(
            19,
            "provider/model/list",
            json!({ "provider": provider }),
        ))
        .await;
    let catalog = harness.response(19).await;
    assert_eq!(catalog["result"]["provider"], json!(provider));
    assert!(
        catalog["result"]["models"]
            .as_array()
            .is_some_and(|models| !models.is_empty())
    );
    if provider == Provider::Codex {
        assert_eq!(
            catalog["result"]["models"].as_array().map(Vec::len),
            Some(2)
        );
        assert_eq!(catalog["result"]["models"][1]["id"], "gpt-m1-fast");
    }

    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            20,
            "provider/session/list",
            json!({ "provider": provider, "cwd": cwd, "limit": 10 }),
        ))
        .await;
    let discovered = harness.response(20).await;
    assert_eq!(
        discovered["result"]["sessions"][0]["provider"],
        json!(provider)
    );
    assert!(
        discovered["result"]["sessions"][0]["provider_session_id"]
            .as_str()
            .is_some_and(|session_id| !session_id.is_empty())
    );
    harness
        .send(request(
            2,
            "agent/start",
            json!({
                "provider": provider,
                "cwd": cwd,
                "workspace_strategy": "shared"
            }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    let provider_session_id = started["result"]["agent"]["provider_session_id"]
        .as_str()
        .expect("provider session id")
        .to_owned();
    assert_eq!(started["result"]["agent"]["provider"], json!(provider));
    let runtime = &started["result"]["agent"]["runtime"];
    match provider {
        Provider::Codex => {
            assert_eq!(
                runtime["compatibility_profile"],
                "codex-app-server-stable-v1"
            );
            assert_eq!(runtime["provider_version"], "0.152.0");
        }
        Provider::Claude => {
            assert_eq!(runtime["compatibility_profile"], "claude-agent-sdk-v1");
            assert_eq!(runtime["provider_version"], "2.1.251");
            assert_eq!(runtime["adapter_version"], "0.2.148");
        }
    }
    harness.state("idle").await;

    harness
        .send(request(
            21,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "range",
                    "payload": {
                        "path": cwd.join("Cargo.toml"),
                        "start_line": 1,
                        "end_line": 1,
                        "text": "[workspace]"
                    }
                }
            }),
        ))
        .await;
    assert_eq!(harness.response(21).await["result"]["queued"], true);

    send_input(&mut harness, 3, "agent/prompt", &agent_id, "first prompt").await;
    assert_eq!(harness.response(3).await["result"]["accepted"], true);
    harness.event("tool.started").await;
    let approval = harness.event("approval.requested").await;
    let approval_id = approval["params"]["payload"]["id"]
        .as_str()
        .expect("approval id")
        .to_owned();
    let waiting_approval = harness.state("waiting_approval").await;
    assert_eq!(
        waiting_approval["params"]["agents"][0]["pending_approvals"],
        1
    );
    harness
        .send(request(
            4,
            "agent/prompt",
            json!({
                "agent_id": agent_id,
                "input": { "text": "follow-up prompt", "attachments": [] },
                "queue": true,
            }),
        ))
        .await;
    assert_eq!(
        harness.response(4).await["result"],
        json!({ "accepted": true, "queued": true, "position": 1 })
    );
    harness
        .send(request(
            27,
            "agent/approval/respond",
            json!({
                "agent_id": agent_id,
                "approval_id": approval_id,
                "decision": "defer"
            }),
        ))
        .await;
    assert_eq!(harness.response(27).await["error"]["code"], -32_021);
    harness
        .send(request(
            22,
            "agent/approval/respond",
            json!({
                "agent_id": agent_id,
                "approval_id": approval_id,
                "decision": "allow"
            }),
        ))
        .await;
    assert_eq!(harness.response(22).await["result"]["resolved"], true);
    harness.event("approval.resolved").await;

    let question = harness.event("question.requested").await;
    let question_id = question["params"]["payload"]["id"]
        .as_str()
        .expect("question id")
        .to_owned();
    assert_eq!(
        question["params"]["payload"]["questions"][0]["question"],
        "Which mode?"
    );
    harness.state("waiting_input").await;
    harness
        .send(request(
            23,
            "agent/question/respond",
            json!({
                "agent_id": agent_id,
                "question_id": question_id,
                "answers": { "mode": "Safe", "Which mode?": "Safe" }
            }),
        ))
        .await;
    assert_eq!(harness.response(23).await["result"]["resolved"], true);
    harness.event("question.resolved").await;
    harness.event("usage.updated").await;
    harness.event("file.changed").await;
    harness.event("message.delta").await;
    harness.event("turn.completed").await;
    // The queued follow-up starts automatically after the first turn completes.
    harness.event("message.delta").await;
    harness.event("turn.completed").await;
    harness.state("completed").await;

    harness
        .send(request(
            24,
            "agent/history",
            json!({ "agent_id": agent_id, "limit": 20 }),
        ))
        .await;
    let history = harness.response(24).await;
    assert_eq!(history["result"]["messages"][0]["role"], "user");
    assert_eq!(history["result"]["messages"][1]["text"], "historic answer");

    send_input(
        &mut harness,
        5,
        "agent/prompt",
        &agent_id,
        "long-running prompt",
    )
    .await;
    assert_eq!(harness.response(5).await["result"]["accepted"], true);
    harness.event("turn.started").await;

    harness
        .send(request(
            29,
            "provider/session/delete",
            json!({
                "provider": provider,
                "provider_session_id": provider_session_id,
                "cwd": cwd,
            }),
        ))
        .await;
    assert_eq!(harness.response(29).await["error"]["code"], -32_013);

    harness.send(request(30, "agent/prompt", json!({
        "agent_id": agent_id, "input": { "text": "cancel this queued prompt", "attachments": [] }, "queue": true,
    }))).await;
    assert_eq!(harness.response(30).await["result"]["queued"], true);

    send_input(&mut harness, 6, "agent/steer", &agent_id, "steering input").await;
    assert_eq!(harness.response(6).await["result"]["accepted"], true);
    harness.event("message.delta").await;

    harness
        .send(request(
            7,
            "agent/interrupt",
            json!({ "agent_id": agent_id }),
        ))
        .await;
    assert_eq!(harness.response(7).await["result"]["interrupted"], true);
    let interrupted = harness.event("turn.completed").await;
    let interrupted_payload = &interrupted["params"]["payload"];
    assert!(
        interrupted_payload["turn"]["status"] == "interrupted"
            || interrupted_payload["subtype"] == "interrupted"
    );
    harness.state("interrupted").await;
    assert!(
        harness.transcript.iter().any(
            |message| message["params"]["payload"]["message"] == "Cancelled 1 queued prompt(s)"
        )
    );

    harness.send(request(8, "agent/list", json!({}))).await;
    let listed = harness.response(8).await;
    assert_eq!(listed["result"]["agents"][0]["id"], agent_id);
    harness
        .send(request(9, "agent/attach", json!({ "agent_id": agent_id })))
        .await;
    assert_eq!(
        harness.response(9).await["result"]["agent"]["state"],
        "interrupted"
    );

    harness
        .send(request(10, "agent/replay", json!({ "after_sequence": 0 })))
        .await;
    let replay = harness.response(10).await;
    let replayed = replay["result"]["events"]
        .as_array()
        .expect("replay event array");
    let sequences = event_sequences(&harness.transcript);
    assert_eq!(replayed.len(), sequences.len());
    assert!(
        sequences
            .windows(2)
            .all(|window| window[1] == window[0] + 1),
        "public event sequences must be contiguous"
    );

    harness
        .send(request(25, "agent/diff", json!({ "agent_id": agent_id })))
        .await;
    let diff = harness.response(25).await;
    assert!(diff["result"]["diff"].is_string());

    harness
        .send(request(28, "workspace/diff", json!({ "cwd": cwd })))
        .await;
    let workspace_diff = harness.response(28).await;
    assert_eq!(
        workspace_diff["result"]["cwd"],
        cwd.to_string_lossy().as_ref()
    );
    assert!(workspace_diff["result"]["diff"].is_string());

    harness
        .send(request(26, "agent/fork", json!({ "agent_id": agent_id })))
        .await;
    let forked = harness.response(26).await;
    assert_ne!(forked["result"]["agent"]["id"], agent_id);
    assert!(
        forked["result"]["agent"]["provider_session_id"]
            .as_str()
            .is_some_and(|session_id| session_id.ends_with("-fork"))
    );
    assert_eq!(forked["result"]["agent"]["state"], "idle");

    harness.shutdown(11).await;
}

async fn send_input(harness: &mut Harness, id: i64, method: &str, agent_id: &str, text: &str) {
    harness
        .send(request(
            id,
            method,
            json!({
                "agent_id": agent_id,
                "input": { "text": text, "attachments": [] }
            }),
        ))
        .await;
}

fn event_sequences(transcript: &[Value]) -> Vec<u64> {
    transcript
        .iter()
        .filter(|message| message["method"] == "agent/event")
        .filter_map(|message| message["params"]["sequence"].as_u64())
        .collect()
}

async fn completes_within(
    future: impl Future<Output = ()>,
) -> Result<(), tokio::time::error::Elapsed> {
    timeout(Duration::from_secs(15), future).await
}

async fn prove_specific_resume(provider: Provider, provider_session_id: &str) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "resume-test", "version": "0.1.0" }
            }),
        ))
        .await;
    assert_eq!(harness.response(1).await["result"]["protocol_version"], 1);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/resume",
            json!({
                "provider": provider,
                "provider_session_id": provider_session_id,
                "cwd": cwd,
                "workspace_strategy": "shared"
            }),
        ))
        .await;
    let resumed = harness.response(2).await;
    assert_eq!(
        resumed["result"]["agent"]["provider_session_id"],
        provider_session_id
    );
    harness.state("idle").await;
    harness.shutdown(3).await;
}

async fn prove_callback_timeout_fails_closed(provider: Provider) {
    let mut harness = Harness::start_with_callback_timeout(Duration::from_millis(40));
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "timeout-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": provider, "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    harness.state("idle").await;
    harness
        .send(request(
            3,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "buffer",
                    "payload": { "path": cwd.join("Cargo.toml"), "text": "[workspace]" }
                }
            }),
        ))
        .await;
    harness.response(3).await;
    send_input(
        &mut harness,
        4,
        "agent/prompt",
        &agent_id,
        "wait for approval",
    )
    .await;
    harness.response(4).await;
    harness.event("approval.requested").await;
    let resolved = harness.event("approval.resolved").await;
    assert_eq!(resolved["params"]["payload"]["decision"], "deny");
    assert_eq!(resolved["params"]["payload"]["reason"], "timeout");
    harness.shutdown(5).await;
}

async fn prove_interrupt_denies_pending_callback(provider: Provider) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "interrupt-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": provider, "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    harness.state("idle").await;
    harness
        .send(request(
            3,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "buffer",
                    "payload": { "path": cwd.join("Cargo.toml"), "text": "[workspace]" }
                }
            }),
        ))
        .await;
    harness.response(3).await;
    send_input(
        &mut harness,
        4,
        "agent/prompt",
        &agent_id,
        "interrupt pending approval",
    )
    .await;
    harness.response(4).await;
    harness.event("approval.requested").await;
    harness
        .send(request(
            5,
            "agent/interrupt",
            json!({ "agent_id": agent_id }),
        ))
        .await;
    let resolved = harness.event("approval.resolved").await;
    assert_eq!(resolved["params"]["payload"]["decision"], "deny");
    assert_eq!(resolved["params"]["payload"]["reason"], "interrupt");
    assert_eq!(harness.response(5).await["result"]["interrupted"], true);
    harness.shutdown(6).await;
}

#[tokio::test]
async fn codex_embedded_flow_streams_follow_up_steer_interrupt_and_replay() {
    completes_within(prove_embedded_flow(Provider::Codex))
        .await
        .expect("Codex embedded flow timed out");
}

#[tokio::test]
async fn claude_embedded_flow_streams_follow_up_steer_interrupt_and_replay() {
    completes_within(prove_embedded_flow(Provider::Claude))
        .await
        .expect("Claude embedded flow timed out");
}

#[tokio::test]
async fn provider_discovery_lists_active_cli_sessions_without_a_cwd_filter() {
    completes_within(async {
        prove_global_active_session_discovery(Provider::Codex).await;
        prove_global_active_session_discovery(Provider::Claude).await;
    })
    .await
    .expect("global active session discovery timed out");
}

async fn prove_provider_session_delete(provider: Provider, lock_directory: &std::path::Path) {
    let codex = fixture_command("fake_m1_codex_app_server.py");
    let claude = fixture_command("fake_m1_claude_worker.py");
    let config = EmbeddedConfig::default()
        .with_provider_commands(
            CommandSpec {
                program: "python".to_owned(),
                args: vec![codex.to_string_lossy().into_owned()],
            },
            WorkerCommandSpec {
                program: "python".to_owned(),
                args: vec![claude.to_string_lossy().into_owned()],
            },
        )
        .with_codex_thread_locks(lock_directory);
    let mut harness = Harness::start_with_config(config);
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "session-delete-test", "version": "0.1.0" }
            }),
        ))
        .await;
    let initialized = harness.response(1).await;
    assert_eq!(initialized["result"]["provider_sessions"]["delete"], true);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;

    let provider_session_id = match provider {
        Provider::Codex => "thread-resumable",
        Provider::Claude => "session-resumable",
    };
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "provider/session/delete",
            json!({
                "provider": provider,
                "provider_session_id": provider_session_id,
                "cwd": cwd,
            }),
        ))
        .await;
    let deleted = harness.response(2).await;
    assert_eq!(deleted["result"]["deleted"], true);
    assert_eq!(
        deleted["result"]["provider_session_id"],
        provider_session_id
    );
    assert_eq!(deleted["result"]["worktree_preserved"], true);
    harness.shutdown(3).await;
}

#[tokio::test]
async fn provider_session_delete_uses_provider_mutation_and_preserves_files() {
    completes_within(async {
        let root = std::env::temp_dir().join(format!(
            "agent-manager-provider-delete-test-{}",
            uuid::Uuid::new_v4()
        ));
        let lock_directory = root.join("thread-writer-locks");
        fs::create_dir_all(&lock_directory).expect("create empty Codex lock directory");
        prove_provider_session_delete(Provider::Codex, &lock_directory).await;
        prove_provider_session_delete(Provider::Claude, &lock_directory).await;
        fs::remove_dir_all(root).expect("remove provider delete fixture");
    })
    .await
    .expect("provider session delete flow timed out");
}

async fn start_managed_harness(fixture: &ManagedWorkspaceFixture) -> Harness {
    let codex = fixture_command("fake_m1_codex_app_server.py");
    let claude = fixture_command("fake_m1_claude_worker.py");
    let lock_directory = fixture.root.join("thread-writer-locks");
    fs::create_dir_all(&lock_directory).expect("create Codex lock directory");
    let config = EmbeddedConfig::default()
        .with_provider_commands(
            CommandSpec {
                program: "python".to_owned(),
                args: vec![codex.to_string_lossy().into_owned()],
            },
            WorkerCommandSpec {
                program: "python".to_owned(),
                args: vec![claude.to_string_lossy().into_owned()],
            },
        )
        .with_codex_thread_locks(lock_directory)
        .with_workspace_lifecycle(fixture.lifecycle.to_string_lossy())
        .with_shared_workspaces(false);
    let mut harness = Harness::start_with_config(config);
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "managed-test", "version": "0.1.0" }
            }),
        ))
        .await;
    let initialized = harness.response(1).await;
    assert_eq!(initialized["result"]["workspaces"]["managed_tasks"], true);
    assert_eq!(initialized["result"]["workspaces"]["shared_starts"], false);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    harness
}

#[tokio::test]
async fn lifecycle_without_a_claim_receipt_uses_the_scoped_audit_fallback() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::without_claim_receipt();
        let mut harness = start_managed_harness(&fixture).await;
        harness
            .send(request(
                2,
                "agent/start",
                json!({
                    "provider": "codex",
                    "managed_workspace": {
                        "repository": "agent-manager",
                        "task_id": "managed-task",
                        "resume": true
                    }
                }),
            ))
            .await;
        assert_eq!(
            harness.response(2).await["result"]["agent"]["state"],
            "idle"
        );
        let lifecycle_calls = fs::read_to_string(&fixture.marker).expect("read lifecycle calls");
        assert_eq!(
            lifecycle_calls
                .lines()
                .filter(|line| line.starts_with("audit "))
                .count(),
            1
        );
        harness.shutdown(3).await;
    })
    .await
    .expect("legacy lifecycle fallback timed out");
}

#[tokio::test]
async fn deleting_an_owned_session_hands_off_but_preserves_its_worktree() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::new();
        let mut harness = start_managed_harness(&fixture).await;
        harness
            .send(request(
                2,
                "agent/start",
                json!({
                    "provider": "codex",
                    "managed_workspace": {
                        "repository": "agent-manager",
                        "task_id": "managed-task",
                        "resume": true
                    }
                }),
            ))
            .await;
        let started = harness.response(2).await;
        assert_eq!(started["result"]["agent"]["state"], "idle");
        harness.state("idle").await;

        harness
            .send(request(
                3,
                "provider/session/delete",
                json!({
                    "provider": "codex",
                    "provider_session_id": "thread-m1",
                    "cwd": fixture.worktree,
                }),
            ))
            .await;
        let deleted = harness.response(3).await;
        assert_eq!(deleted["result"]["deleted"], true);
        assert_eq!(deleted["result"]["workspace_handed_off"], true);
        assert_eq!(deleted["result"]["worktree_preserved"], true);
        assert!(fixture.worktree.join("README.md").is_file());

        harness.send(request(4, "agent/list", json!({}))).await;
        assert_eq!(harness.response(4).await["result"]["agents"], json!([]));
        let lifecycle_calls = fs::read_to_string(&fixture.marker).expect("read lifecycle calls");
        assert!(lifecycle_calls.contains("handoff agent-manager managed-task --owner-pid"));
        harness.shutdown(5).await;
    })
    .await
    .expect("managed provider session delete flow timed out");
}

#[tokio::test]
async fn managed_workspace_refusal_reports_safe_reason_and_drains_stderr() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::new();
        fs::write(
            &fixture.lifecycle,
            "#!/usr/bin/env python3\nimport sys\nsys.stderr.write('REFUSE dirty_canonical: private payload\\n' + 'private payload' * 100000)\nsys.exit(1)\n",
        )
        .expect("write refusing lifecycle fixture");
        let mut harness = start_managed_harness(&fixture).await;
        harness
            .send(request(
                2,
                "agent/start",
                json!({
                    "provider": "codex",
                    "managed_workspace": {
                        "repository": "agent-manager",
                        "task_id": "managed-task",
                        "resume": false
                    }
                }),
            ))
            .await;
        let response = harness.response(2).await;
        let message = response["error"]["message"].as_str().expect("refusal message");
        assert!(message.contains("canonical checkout has uncommitted changes"));
        assert!(!response.to_string().contains("private payload"));
        harness.send(request(3, "agent/list", json!({}))).await;
        assert_eq!(harness.response(3).await["result"]["agents"], json!([]));
        harness.shutdown(4).await;
    })
    .await
    .expect("workspace refusal flow timed out");
}

#[tokio::test]
async fn managed_workspace_start_uses_validated_lifecycle_claim_and_handoff() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::new();
        let mut harness = start_managed_harness(&fixture).await;

        harness.send(request(2, "workspace/list", json!({}))).await;
        let inventory = harness.response(2).await;
        assert_eq!(
            inventory["result"]["repositories"][0]["base_branch"],
            "bluff"
        );
        assert_eq!(
            inventory["result"]["repositories"][0]["tasks"][0]["task_id"],
            "managed-task"
        );

        harness
            .send(request(
                20,
                "agent/start",
                json!({
                    "provider": "codex",
                    "cwd": fixture.worktree,
                    "workspace_strategy": "shared"
                }),
            ))
            .await;
        assert_eq!(harness.response(20).await["error"]["code"], -32_031);

        harness
            .send(request(
                3,
                "agent/start",
                json!({
                    "provider": "codex",
                    "managed_workspace": {
                        "repository": "agent-manager",
                        "task_id": "managed-task",
                        "resume": true
                    }
                }),
            ))
            .await;
        let started = harness.response(3).await;
        let agent = &started["result"]["agent"];
        let agent_id = agent["id"].as_str().expect("managed agent id").to_owned();
        assert_eq!(agent["cwd"], fixture.worktree.to_string_lossy().as_ref());
        assert_eq!(agent["workspace_strategy"], "worktree");
        assert_eq!(agent["managed_workspace"]["repository"], "agent-manager");
        assert_eq!(agent["managed_workspace"]["base_branch"], "bluff");
        assert_eq!(
            agent["runtime"]["compatibility_profile"],
            "codex-app-server-stable-v1"
        );
        assert_eq!(agent["runtime"]["provider_version"], "0.152.0");

        harness
            .send(request(
                4,
                "workspace/handoff",
                json!({ "repository": "agent-manager", "task_id": "managed-task" }),
            ))
            .await;
        assert_eq!(harness.response(4).await["error"]["code"], -32_013);

        harness
            .send(request(5, "agent/archive", json!({ "agent_id": agent_id })))
            .await;
        assert_eq!(harness.response(5).await["result"]["archived"], true);
        harness
            .send(request(
                6,
                "workspace/handoff",
                json!({ "repository": "agent-manager", "task_id": "managed-task" }),
            ))
            .await;
        assert_eq!(harness.response(6).await["result"]["handed_off"], true);
        let lifecycle_calls = fs::read_to_string(&fixture.marker).expect("read lifecycle calls");
        assert!(lifecycle_calls.contains("claim agent-manager managed-task --owner-pid"));
        assert!(lifecycle_calls.contains("handoff agent-manager managed-task --owner-pid"));
        assert_eq!(
            lifecycle_calls
                .lines()
                .filter(|line| line.starts_with("audit "))
                .count(),
            1,
            "the explicit inventory call is the only lifecycle audit"
        );
        harness.shutdown(7).await;
    })
    .await
    .expect("managed workspace flow timed out");
}

#[tokio::test]
async fn managed_workspace_resume_claims_the_saved_task_before_provider_resume() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::new();
        let mut harness = start_managed_harness(&fixture).await;

        harness
            .send(request(
                2,
                "agent/resume",
                json!({
                    "provider": "codex",
                    "provider_session_id": "thread-resumable",
                    "managed_workspace": {
                        "repository": "agent-manager",
                        "task_id": "managed-task",
                        "resume": true
                    }
                }),
            ))
            .await;
        let resumed = harness.response(2).await;
        let agent = &resumed["result"]["agent"];
        assert_eq!(agent["provider_session_id"], "thread-resumable");
        assert_eq!(agent["cwd"], fixture.worktree.to_string_lossy().as_ref());
        assert_eq!(agent["workspace_strategy"], "worktree");
        assert_eq!(agent["managed_workspace"]["repository"], "agent-manager");
        assert_eq!(agent["managed_workspace"]["task_id"], "managed-task");
        harness.state("idle").await;

        let lifecycle_calls = fs::read_to_string(&fixture.marker).expect("read lifecycle calls");
        assert!(lifecycle_calls.contains("claim agent-manager managed-task --owner-pid"));
        assert!(lifecycle_calls.contains("--resume"));
        assert!(
            !lifecycle_calls
                .lines()
                .any(|line| line.starts_with("audit ")),
            "a validated resume receipt must not trigger a cleanup audit"
        );
        harness.shutdown(3).await;
    })
    .await
    .expect("managed workspace resume timed out");
}

#[tokio::test]
async fn codex_directory_resume_skips_lifecycle_with_shared_starts_disabled() {
    completes_within(async {
        let fixture = ManagedWorkspaceFixture::new();
        let mut harness = start_managed_harness(&fixture).await;

        // The exception is specific to Codex resume outside a checkout.
        let canonical = fixture.root.join("canonical");
        let nested = canonical.join("nested");
        fs::create_dir(&nested).expect("create nested checkout directory");
        let broken = fixture.root.join("broken-checkout");
        fs::create_dir(&broken).expect("create broken checkout directory");
        fs::write(broken.join(".git"), "gitdir: /missing/gitdir\n")
            .expect("write broken Git marker");
        for (id, method, provider, cwd) in [
            (2, "agent/start", "codex", &fixture.root),
            (3, "agent/resume", "claude", &fixture.root),
            (4, "agent/resume", "codex", &canonical),
            (5, "agent/resume", "codex", &nested),
            (6, "agent/resume", "codex", &fixture.worktree),
            (7, "agent/resume", "codex", &broken),
        ] {
            let mut params = json!({
                "provider": provider, "cwd": cwd, "workspace_strategy": "shared"
            });
            if method == "agent/resume" {
                params["provider_session_id"] = json!("thread-resumable");
            }
            harness.send(request(id, method, params)).await;
            assert_eq!(harness.response(id).await["error"]["code"], -32_031);
        }

        harness
            .send(request(
                8,
                "agent/resume",
                json!({
                    "provider": "codex", "provider_session_id": "thread-resumable",
                    "cwd": fixture.root, "workspace_strategy": "shared"
                }),
            ))
            .await;
        let resumed = harness.response(8).await;
        let agent = &resumed["result"]["agent"];
        assert_eq!(agent["provider_session_id"], "thread-resumable");
        assert_eq!(agent["cwd"], fixture.root.to_string_lossy().as_ref());
        assert_eq!(agent["workspace_strategy"], "shared");
        assert!(agent["managed_workspace"].is_null());
        harness.state("idle").await;
        harness
            .send(request(
                9,
                "agent/history",
                json!({ "agent_id": agent["id"] }),
            ))
            .await;
        let history = harness.response(9).await;
        assert!(
            history["result"]["messages"]
                .as_array()
                .is_some_and(|items| !items.is_empty())
        );
        assert!(
            !fixture.marker.exists(),
            "directory resume must never invoke lifecycle"
        );
        harness.shutdown(10).await;
    })
    .await
    .expect("Codex directory resume timed out");
}

#[tokio::test]
async fn codex_embedded_flow_resumes_one_specific_provider_session() {
    completes_within(prove_specific_resume(Provider::Codex, "thread-resumable"))
        .await
        .expect("Codex resume timed out");
}

#[tokio::test]
async fn claude_embedded_flow_resumes_one_specific_provider_session() {
    completes_within(prove_specific_resume(Provider::Claude, "session-resumable"))
        .await
        .expect("Claude resume timed out");
}

#[tokio::test]
async fn provider_callbacks_time_out_fail_closed() {
    completes_within(async {
        prove_callback_timeout_fails_closed(Provider::Codex).await;
        prove_callback_timeout_fails_closed(Provider::Claude).await;
    })
    .await
    .expect("callback timeout flow timed out");
}

#[tokio::test]
async fn interrupt_denies_pending_provider_callbacks() {
    completes_within(async {
        prove_interrupt_denies_pending_callback(Provider::Codex).await;
        prove_interrupt_denies_pending_callback(Provider::Claude).await;
    })
    .await
    .expect("callback interrupt flow timed out");
}

#[tokio::test]
async fn public_boundary_rejects_malformed_uninitialized_and_unknown_requests() {
    let mut harness = Harness::start();
    harness.send_raw(b"{not-json}\n").await;
    let parse_error = harness.receive().await;
    assert_eq!(parse_error["id"], Value::Null);
    assert_eq!(parse_error["error"]["code"], -32_700);

    harness.send(request(1, "agent/list", json!({}))).await;
    assert_eq!(harness.response(1).await["error"]["code"], -32_002);

    harness
        .send(request(
            2,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "negative-test", "version": "0.1.0" }
            }),
        ))
        .await;
    assert_eq!(harness.response(2).await["result"]["protocol_version"], 1);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;

    harness.send(request(3, "future/method", json!({}))).await;
    assert_eq!(harness.response(3).await["error"]["code"], -32_601);
    harness.shutdown(4).await;
}

#[tokio::test]
async fn failed_provider_start_releases_the_embedded_live_slot() {
    let claude = fixture_command("fake_m1_claude_worker.py");
    let mut harness = Harness::start_with_provider_commands(
        Duration::from_secs(300),
        CommandSpec {
            program: "/definitely/missing/agent-manager-codex".to_owned(),
            args: Vec::new(),
        },
        WorkerCommandSpec {
            program: "python".to_owned(),
            args: vec![claude.to_string_lossy().into_owned()],
        },
    );
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "recovery-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": "codex", "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    assert_eq!(harness.response(2).await["error"]["code"], -32_020);
    harness.state("disconnected").await;

    harness
        .send(request(
            3,
            "agent/start",
            json!({ "provider": "claude", "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    assert_eq!(
        harness.response(3).await["result"]["agent"]["provider"],
        "claude"
    );
    harness.shutdown(4).await;
}
