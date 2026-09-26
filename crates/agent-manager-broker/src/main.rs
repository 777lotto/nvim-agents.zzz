use std::env;
use std::io;
use std::path::{Path, PathBuf};

use agent_manager_broker::codex::{
    CODEX_COMPATIBILITY_PROFILE, CODEX_SCHEMA_BASELINE_VERSION, CodexAppServer, CommandSpec,
    normalize_event, runtime_identity as codex_runtime_identity, thread_id,
};
use agent_manager_broker::durable::{self, DurableConfig};
use agent_manager_broker::embedded::{self, EmbeddedConfig};
use agent_manager_broker::protocol::{PROTOCOL_REVISION, PROTOCOL_VERSION};
use agent_manager_broker::worker::{
    CLAUDE_COMPATIBILITY_PROFILE, TESTED_CLAUDE_CODE_VERSION, TESTED_CLAUDE_SDK_VERSION,
    WORKER_PROTOCOL_VERSION, parse_setting_sources,
};
use agent_manager_broker::{BROKER_VERSION, codex};
use serde_json::{Value, json};
use tokio::io::BufReader;

const LIVE_CONFIRMATION: &str = "--allow-live-provider";

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("agent-manager-broker: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("help" | "--help" | "-h") => {
            print_help();
            Ok(())
        }
        Some("contract-info") => {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "broker_version": BROKER_VERSION,
                    "broker_protocol_version": PROTOCOL_VERSION,
                    "broker_protocol_revision": PROTOCOL_REVISION,
                    "codex_compatibility_profile": CODEX_COMPATIBILITY_PROFILE,
                    "codex_schema_baseline_version": CODEX_SCHEMA_BASELINE_VERSION,
                    "claude_worker_protocol_version": WORKER_PROTOCOL_VERSION,
                    "claude_compatibility_profile": CLAUDE_COMPATIBILITY_PROFILE,
                    "tested_claude_agent_sdk_version": TESTED_CLAUDE_SDK_VERSION,
                    "tested_claude_code_version": TESTED_CLAUDE_CODE_VERSION
                }))?
            );
            Ok(())
        }
        Some("serve") => serve_embedded(&args[1..]).await,
        Some("serve-durable") => serve_durable(&args[1..]).await,
        Some("codex-probe") => probe_codex(parse_cwd(&args[1..])?).await,
        Some("codex-trace") => trace_codex(&args[1..]).await,
        Some(command) => Err(invalid_input(format!("unknown command: {command}")).into()),
    }
}

async fn serve_durable(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let mut broker = EmbeddedConfig::default();
    let mut socket = None;
    let mut registry = None;
    let mut status = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--socket" => {
                socket = Some(absolute_option(args, index, "--socket")?);
                index += 2;
            }
            "--registry" => {
                registry = Some(absolute_option(args, index, "--registry")?);
                index += 2;
            }
            "--status" => {
                status = Some(absolute_option(args, index, "--status")?);
                index += 2;
            }
            "--claude-python" => {
                let python = absolute_option(args, index, "--claude-python")?;
                broker = broker.with_claude_python(python.to_string_lossy());
                index += 2;
            }
            "--claude-setting-sources" => {
                broker = broker.with_claude_setting_sources(setting_sources_option(args, index)?);
                index += 2;
            }
            "--codex-bin" => {
                let executable = absolute_option(args, index, "--codex-bin")?;
                broker = broker.with_codex_program(executable.to_string_lossy());
                index += 2;
            }
            "--workspace-lifecycle" => {
                let executable = absolute_option(args, index, "--workspace-lifecycle")?;
                broker = broker.with_workspace_lifecycle(executable.to_string_lossy());
                index += 2;
            }
            "--disable-workspace-lifecycle" => {
                broker = broker.without_workspace_lifecycle();
                index += 1;
            }
            "--deny-shared-workspaces" => {
                broker = broker.with_shared_workspaces(false);
                index += 1;
            }
            option => {
                return Err(
                    invalid_input(format!("unknown serve-durable option: {option}")).into(),
                );
            }
        }
    }
    let socket = socket.map_or_else(default_socket_path, Ok)?;
    let registry = registry.map_or_else(default_registry_path, Ok)?;
    let mut config = DurableConfig::new(socket, registry).with_broker_config(broker);
    if let Some(status) = status {
        config = config.with_status_path(status);
    }
    durable::serve(config).await?;
    Ok(())
}

async fn serve_embedded(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let mut config = EmbeddedConfig::default();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--claude-python" => {
                let python = args
                    .get(index + 1)
                    .ok_or_else(|| invalid_input("--claude-python requires an absolute path"))?;
                if !Path::new(python).is_absolute() {
                    return Err(invalid_input("--claude-python requires an absolute path").into());
                }
                config = config.with_claude_python(python);
                index += 2;
            }
            "--claude-setting-sources" => {
                config = config.with_claude_setting_sources(setting_sources_option(args, index)?);
                index += 2;
            }
            "--codex-bin" => {
                let executable = args
                    .get(index + 1)
                    .ok_or_else(|| invalid_input("--codex-bin requires an absolute path"))?;
                if !Path::new(executable).is_absolute() {
                    return Err(invalid_input("--codex-bin requires an absolute path").into());
                }
                config = config.with_codex_program(executable);
                index += 2;
            }
            "--workspace-lifecycle" => {
                let executable = args.get(index + 1).ok_or_else(|| {
                    invalid_input("--workspace-lifecycle requires an absolute path")
                })?;
                if !Path::new(executable).is_absolute() {
                    return Err(
                        invalid_input("--workspace-lifecycle requires an absolute path").into(),
                    );
                }
                config = config.with_workspace_lifecycle(executable);
                index += 2;
            }
            "--disable-workspace-lifecycle" => {
                config = config.without_workspace_lifecycle();
                index += 1;
            }
            "--deny-shared-workspaces" => {
                config = config.with_shared_workspaces(false);
                index += 1;
            }
            option => {
                return Err(invalid_input(format!("unknown serve option: {option}")).into());
            }
        }
    }
    embedded::serve(
        BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
        config,
    )
    .await?;
    Ok(())
}

async fn probe_codex(cwd: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    ensure_directory(&cwd)?;
    let spec = CommandSpec::default();
    let mut server = CodexAppServer::spawn(&spec)?;
    let initialize = server.initialize().await?;
    let runtime = codex_runtime_identity(&initialize, &spec)?;
    let threads = server.list_threads(None, 1).await?;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "initialized": true,
            "runtime": runtime,
            "user_agent": initialize.get("userAgent"),
            "platform_family": initialize.get("platformFamily"),
            "platform_os": initialize.get("platformOs"),
            "thread_list_shape": value_shape(&threads.result),
            "events_seen": threads.events.iter().map(|event| &event.method).collect::<Vec<_>>()
        }))?
    );
    server.shutdown().await?;
    Ok(())
}

async fn trace_codex(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if !args.iter().any(|arg| arg == LIVE_CONFIRMATION) {
        return Err(
            invalid_input(format!("codex-trace requires explicit {LIVE_CONFIRMATION}")).into(),
        );
    }
    let cwd = parse_cwd(args)?;
    ensure_directory(&cwd)?;
    let prompt = option_value(args, "--prompt")
        .ok_or_else(|| invalid_input("codex-trace requires --prompt"))?;

    let spec = CommandSpec::default();
    let mut server = CodexAppServer::spawn(&spec)?;
    let initialize = server.initialize().await?;
    codex_runtime_identity(&initialize, &spec)?;
    let started = server.start_thread(&cwd, None).await?;
    let thread_id = thread_id(&started.result)
        .ok_or_else(|| invalid_input("thread/start response omitted thread.id"))?
        .to_owned();
    let turn = server.start_turn(&thread_id, prompt, None, None).await?;
    let mut next_sequence = 1;
    for event in started.events.into_iter().chain(turn.events) {
        print_event(&event, &mut next_sequence)?;
    }
    loop {
        let mut event = server.next_event().await?;
        let completed = event.method == "turn/completed";
        if event.response_required {
            server.deny_server_request(&mut event).await?;
        }
        print_event(&event, &mut next_sequence)?;
        if completed {
            break;
        }
    }
    server.shutdown().await?;
    Ok(())
}

fn print_event(
    event: &codex::ProviderEvent,
    next_sequence: &mut u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut normalized = normalize_event("m0-probe", event)?;
    normalized.sequence = *next_sequence;
    *next_sequence = next_sequence
        .checked_add(1)
        .ok_or_else(|| io::Error::other("diagnostic sequence overflow"))?;
    println!(
        "{}",
        serde_json::to_string(&json!({
            "sequence": normalized.sequence,
            "timestamp": normalized.timestamp,
            "type": normalized.event_type,
            "provider_method": normalized.provider_event["method"]
        }))?
    );
    Ok(())
}

fn parse_cwd(args: &[String]) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let cwd = option_value(args, "--cwd").ok_or_else(|| invalid_input("command requires --cwd"))?;
    Ok(PathBuf::from(cwd))
}

fn option_value<'a>(args: &'a [String], option: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|window| window[0] == option)
        .map(|window| window[1].as_str())
}

fn absolute_option(
    args: &[String],
    index: usize,
    option: &str,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let value = args
        .get(index + 1)
        .ok_or_else(|| invalid_input(format!("{option} requires an absolute path")))?;
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(invalid_input(format!("{option} requires an absolute path")).into());
    }
    Ok(path)
}

fn default_socket_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| {
            invalid_input(
                "durable mode requires an absolute XDG_RUNTIME_DIR or an explicit --socket path",
            )
        })?;
    Ok(runtime.join("agent-manager").join("broker.sock"))
}

fn default_registry_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let state_root = match env::var_os("XDG_STATE_HOME").map(PathBuf::from) {
        Some(path) if path.is_absolute() => path,
        Some(_) => {
            return Err(invalid_input("XDG_STATE_HOME must be absolute").into());
        }
        None => env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .ok_or_else(|| invalid_input("durable mode could not resolve an absolute state path"))?
            .join(".local")
            .join("state"),
    };
    Ok(state_root.join("agent-manager").join("registry.json"))
}

fn ensure_directory(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if !path.is_absolute() || !path.is_dir() {
        return Err(invalid_input("cwd must be an existing absolute directory").into());
    }
    Ok(())
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn setting_sources_option(args: &[String], index: usize) -> Result<Vec<String>, io::Error> {
    let raw = args
        .get(index + 1)
        .ok_or_else(|| invalid_input("--claude-setting-sources requires a comma-separated list"))?;
    parse_setting_sources(raw).map_err(invalid_input)
}

fn value_shape(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn print_help() {
    println!(
        "agent-manager-broker {BROKER_VERSION}\n\
         \n\
         Commands:\n\
           contract-info\n\
           serve [--codex-bin ABSOLUTE_PATH] [--claude-python ABSOLUTE_PATH]\n\
                 [--claude-setting-sources user,project,local]\n\
                 [--workspace-lifecycle ABSOLUTE_PATH | --disable-workspace-lifecycle]\n\
                 [--deny-shared-workspaces]\n\
           serve-durable [--socket ABSOLUTE_PATH] [--registry ABSOLUTE_PATH]\n\
                         [--status ABSOLUTE_PATH]\n\
                         [--codex-bin ABSOLUTE_PATH] [--claude-python ABSOLUTE_PATH]\n\
                         [--claude-setting-sources user,project,local]\n\
                         [--workspace-lifecycle ABSOLUTE_PATH | --disable-workspace-lifecycle]\n\
                         [--deny-shared-workspaces]\n\
           codex-probe --cwd ABSOLUTE_PATH\n\
           codex-trace --cwd ABSOLUTE_PATH --prompt TEXT {LIVE_CONFIRMATION}\n\
         \n\
         serve runs the embedded Neovim JSON-RPC broker over stdio.\n\
         serve-durable runs the owner-only Unix-socket broker until supervised shutdown.\n\
         codex-probe performs initialization and history discovery only.\n\
         codex-trace invokes the live provider and is never run by verification."
    );
}
