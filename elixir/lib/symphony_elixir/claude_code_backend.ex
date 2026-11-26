defmodule SymphonyElixir.ClaudeCodeBackend do
  @moduledoc """
  Claude Code CLI backend using non-interactive newline-delimited `stream-json`.

  Prompts are framed through stdin into a mode-0600 temporary file owned by the
  child shell, so prompt contents never become shell arguments or log fields.
  """

  @behaviour SymphonyElixir.AgentServer

  require Logger

  alias SymphonyElixir.AgentServer
  alias SymphonyElixir.AgentServer.{Approval, Error, Event, Usage, WorkspaceGuard}
  alias SymphonyElixir.{ClaudeTrackerMCP, Config, HttpServer, PathSafety, SSH, Tracker}

  @max_stream_frame_bytes 10_485_760
  @port_line_bytes @max_stream_frame_bytes + 1
  @post_exit_drain_ms 25
  @termination_grace_ms 250
  @stderr_diagnostic_bytes 2_048
  @stderr_read_limit_bytes 65_536
  @stderr_read_timeout_ms 2_000
  @nested_environment_marker_names ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
  @mcp_config_file_placeholder "__SYMPHONY_CLAUDE_MCP_CONFIG_FILE__"
  @tracker_mcp_path "/api/v1/agent-mcp"
  @transient_error_pattern ~r/(?:^|[^a-z0-9])(?:429|rate[_ -]?limit(?:ed)?|timeout|overload(?:ed)?|temporar(?:y|ily)|unavailable|connection(?:[_ -]?(?:reset|refused|closed|error))?|econnreset|econnrefused|too many requests)(?:$|[^a-z0-9])/

  @type session :: %{
          backend: :claude_code,
          session_id: String.t(),
          initial_session_id: String.t(),
          resume_session_id: String.t() | nil,
          thread_id: String.t(),
          workspace: Path.t(),
          workspace_root: Path.t(),
          worker_host: String.t() | nil,
          turn_count: non_neg_integer(),
          runtime_settings: Config.claude_code_runtime_settings(),
          tracker_binding: map()
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_session_workspace(workspace, worker_host) do
      {:ok, %{workspace: safe_workspace, workspace_root: workspace_root}} ->
        session_id = uuid4()
        runtime_settings = Config.claude_code_runtime_settings()
        tracker_binding = Tracker.bind_agent_tools()

        {:ok,
         %{
           backend: :claude_code,
           session_id: session_id,
           initial_session_id: session_id,
           resume_session_id: nil,
           thread_id: session_id,
           workspace: safe_workspace,
           workspace_root: workspace_root,
           worker_host: worker_host,
           turn_count: 0,
           runtime_settings: runtime_settings,
           tracker_binding: tracker_binding
         }}

      {:error, reason} ->
        {:error, AgentServer.normalize_error(reason, :startup)}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ [])
      when is_map(session) and is_binary(prompt) and is_map(issue) do
    case validate_turn_workspace(session) do
      {:ok, safe_workspace} ->
        do_run_turn(%{session | workspace: safe_workspace}, prompt, issue, opts)

      {:error, reason} ->
        on_message = Keyword.get(opts, :on_message, fn _event -> :ok end)
        error = AgentServer.normalize_error(reason, :startup)

        emit(on_message, :startup_failed, %{
          session_id: Map.get(session, :resume_session_id) || Map.get(session, :session_id),
          thread_id: Map.get(session, :thread_id),
          turn_id: "turn-#{Map.get(session, :turn_count, 0) + 1}",
          worker_host: Map.get(session, :worker_host),
          error: error,
          payload: %{reason: :invalid_workspace}
        })

        {:error, error}
    end
  end

  defp do_run_turn(session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _event -> :ok end)
    settings = session_runtime_settings(session)
    turn_id = "turn-#{session.turn_count + 1}"
    current_session_id = session.resume_session_id || session.session_id

    base = %{
      session_id: current_session_id,
      thread_id: session.thread_id,
      turn_id: turn_id,
      worker_host: session.worker_host
    }

    Logger.info("Claude Code turn starting for #{issue_context(issue)} session_id=#{current_session_id} turn_id=#{turn_id} worker_host=#{worker_host_for_log(session.worker_host)}")

    case prepare_tracker_mcp(session, issue, settings, current_session_id, turn_id) do
      {:ok, turn_settings, tracker_mcp_token} ->
        try do
          run_prepared_turn(session, prompt, issue, on_message, base, turn_settings)
        after
          ClaudeTrackerMCP.close(tracker_mcp_token)
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason, :startup)
        emit(on_message, :startup_failed, Map.merge(base, %{error: error, payload: reason}))
        {:error, error}
    end
  end

  defp run_prepared_turn(session, prompt, issue, on_message, base, settings) do
    args = cli_args(session, settings)
    input = framed_input(settings.mcp_config, prompt)

    case start_port(session, settings, args, byte_size(prompt), mcp_config_bytes(settings.mcp_config)) do
      {:ok, port, cleanup} ->
        try do
          metadata = Map.put(base, :process_id, port_process_id(port))
          emit(on_message, :session_started, metadata)

          case command_port(port, input) do
            :ok ->
              case receive_stream(port, on_message, metadata, settings.turn_timeout_ms, "", nil) do
                {:ok, provider_session_id, usage, payload} ->
                  updated_session = %{
                    session
                    | session_id: provider_session_id,
                      resume_session_id: provider_session_id,
                      turn_count: session.turn_count + 1
                  }

                  Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{provider_session_id} turn_id=#{base.turn_id}")

                  {:ok,
                   %{
                     result: :turn_completed,
                     session_id: provider_session_id,
                     thread_id: session.thread_id,
                     turn_id: base.turn_id,
                     usage: usage,
                     payload: payload,
                     session: updated_session
                   }}

                {:error, %Error{} = error} ->
                  Logger.warning("Claude Code turn failed for #{issue_context(issue)} turn_id=#{base.turn_id} kind=#{error.kind} code=#{inspect(error.code)}")

                  {:error, error}
              end

            {:error, %Error{} = error} ->
              emit(on_message, :turn_failed, Map.merge(metadata, %{error: error, payload: %{reason: :port_closed}}))
              {:error, error}
          end
        after
          stop_port_and_cleanup(port, cleanup)
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason, :startup)
        emit(on_message, :startup_failed, Map.merge(base, %{error: error, payload: reason}))
        {:error, error}
    end
  end

  defp prepare_tracker_mcp(%{worker_host: worker_host}, _issue, settings, _session_id, _turn_id)
       when is_binary(worker_host) do
    {:ok, settings, nil}
  end

  defp prepare_tracker_mcp(session, issue, settings, session_id, turn_id) do
    tool_specs = Map.get(session.tracker_binding, :scoped_tool_specs, [])

    if auto_tracker_mcp?(tool_specs, settings.mcp_config) do
      open_tracker_mcp(session, issue, settings, session_id, turn_id, tool_specs)
    else
      {:ok, settings, nil}
    end
  end

  defp auto_tracker_mcp?(tool_specs, mcp_config) do
    tool_specs != [] and mergeable_mcp_config?(mcp_config) and not is_nil(tracker_mcp_port())
  end

  defp mergeable_mcp_config?(config) when is_binary(config), do: not is_nil(inline_mcp_payload(config))
  defp mergeable_mcp_config?(_config), do: true

  defp open_tracker_mcp(session, issue, settings, session_id, turn_id, tool_specs) do
    case ClaudeTrackerMCP.open(
           session.tracker_binding,
           issue,
           session_id,
           turn_id,
           ttl_ms: settings.turn_timeout_ms + 60_000
         ) do
      {:ok, token} -> prepare_opened_tracker_mcp(settings, tool_specs, token)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_opened_tracker_mcp(settings, tool_specs, token) do
    case merge_tracker_mcp_config(settings.mcp_config, token) do
      {:ok, merged_config} ->
        allowed_tools = Enum.uniq(settings.allowed_tools ++ tracker_mcp_allowed_tools(tool_specs))
        {:ok, %{settings | mcp_config: merged_config, allowed_tools: allowed_tools}, token}

      {:error, _reason} = error ->
        ClaudeTrackerMCP.close(token)
        error
    end
  end

  defp merge_tracker_mcp_config(config, token) do
    config_map = inline_mcp_payload(config) |> decode_inline_mcp_config()
    servers = Map.get(config_map, "mcpServers", %{})
    server_name = ClaudeTrackerMCP.server_name()

    cond do
      not is_map(servers) ->
        {:error, :invalid_claude_mcp_servers}

      Map.has_key?(servers, server_name) ->
        {:error, :claude_tracker_mcp_name_conflict}

      true ->
        tracker_server = %{
          "type" => "http",
          "url" => tracker_mcp_url(),
          "headers" => %{"Authorization" => "Bearer #{token}"}
        }

        {:ok, Map.put(config_map, "mcpServers", Map.put(servers, server_name, tracker_server))}
    end
  end

  defp decode_inline_mcp_config(nil), do: %{}

  defp decode_inline_mcp_config(payload) when is_binary(payload) do
    Jason.decode!(payload)
  end

  defp tracker_mcp_allowed_tools(tool_specs) do
    Enum.map(tool_specs, fn spec ->
      "mcp__#{ClaudeTrackerMCP.server_name()}__#{Map.fetch!(spec, "name")}"
    end)
  end

  defp tracker_mcp_url do
    "http://#{tracker_mcp_host()}:#{tracker_mcp_port()}#{@tracker_mcp_path}"
  end

  defp tracker_mcp_port do
    HttpServer.bound_port() || Config.server_port()
  end

  defp tracker_mcp_host do
    case Config.settings!().server.host do
      host when host in [nil, "", "0.0.0.0", "::", "[::]"] -> "127.0.0.1"
      host -> host
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp cli_args(session, settings) do
    [
      "--print",
      "--input-format",
      "text",
      "--output-format",
      "stream-json",
      "--verbose",
      "--setting-sources",
      "user",
      "--strict-mcp-config"
    ]
    |> maybe_add_flag(settings.include_partial_messages, "--include-partial-messages")
    |> add_session_args(session)
    |> maybe_add_option("--model", settings.model)
    |> maybe_add_option("--permission-mode", settings.permission_mode)
    |> add_repeated_options("--allowedTools", settings.allowed_tools)
    |> add_repeated_options("--disallowedTools", settings.disallowed_tools)
    |> maybe_add_option("--mcp-config", mcp_config_argument(settings.mcp_config))
  end

  defp add_session_args(args, %{resume_session_id: resume_session_id}) when is_binary(resume_session_id) do
    args ++ ["--resume", resume_session_id]
  end

  defp add_session_args(args, %{session_id: session_id}) do
    args ++ ["--session-id", session_id]
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _enabled, _flag), do: args

  defp maybe_add_option(args, _flag, nil), do: args
  defp maybe_add_option(args, _flag, ""), do: args
  defp maybe_add_option(args, flag, value) when is_binary(value), do: args ++ [flag, value]

  defp add_repeated_options(args, flag, values) when is_list(values) do
    Enum.reduce(values, args, fn value, acc -> maybe_add_option(acc, flag, value) end)
  end

  defp mcp_config_argument(nil), do: nil

  defp mcp_config_argument(value) do
    if inline_mcp_payload(value), do: @mcp_config_file_placeholder, else: value
  end

  defp start_port(session, settings, args, prompt_bytes, mcp_bytes) do
    case session.worker_host do
      nil ->
        local_temp_dir = create_local_temp_dir()

        launch_script =
          launch_script(
            settings.command,
            args,
            prompt_bytes,
            mcp_bytes,
            session.tracker_binding,
            local_temp_dir,
            nil
          )

        case start_local_port(session.workspace, launch_script, session.tracker_binding) do
          {:ok, port} -> {:ok, port, local_temp_dir}
          {:error, _reason} = error -> cleanup_local_temp_dir(local_temp_dir, error)
        end

      worker_host ->
        remote_stderr_ref = remote_stderr_diagnostic_ref()

        launch_script =
          launch_script(
            settings.command,
            args,
            prompt_bytes,
            mcp_bytes,
            session.tracker_binding,
            nil,
            remote_stderr_ref
          )

        case start_remote_port(session, worker_host, launch_script) do
          {:ok, port} -> {:ok, port, {:remote, worker_host, remote_stderr_ref}}
          {:error, _reason} = error -> cleanup_local_temp_dir(nil, error)
        end
    end
  end

  defp start_local_port(workspace, launch_script, tracker_binding) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              args: [~c"-lc", String.to_charlist(launch_script)],
              cd: String.to_charlist(workspace),
              env: nested_marker_port_env() ++ tracker_secret_port_env(tracker_binding),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:port_open_failed, error}}
  end

  defp start_remote_port(session, worker_host, launch_script) do
    remote_command = remote_launch_script(session.workspace, session.workspace_root, launch_script)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes, stderr_to_stdout: false)
  end

  defp remote_launch_script(workspace, workspace_root, launch_script) do
    [
      "set -u",
      "workspace=#{shell_escape(workspace)}",
      "workspace_root=#{shell_escape(workspace_root)}",
      ~s|case "$workspace" in "~") workspace="$HOME" ;; "~/"*) workspace="$HOME/${workspace#*/}" ;; esac|,
      ~s|case "$workspace_root" in "~") workspace_root="$HOME" ;; "~/"*) workspace_root="$HOME/${workspace_root#*/}" ;; esac|,
      "canonical_workspace=$(cd -- \"$workspace\" 2>/dev/null && pwd -P) || exit 126",
      "canonical_root=$(cd -- \"$workspace_root\" 2>/dev/null && pwd -P) || exit 126",
      "[ \"$canonical_workspace\" != \"$canonical_root\" ] || exit 126",
      "if [ \"$canonical_root\" = \"/\" ]; then case \"$canonical_workspace\" in /*) ;; *) exit 126 ;; esac; else case \"$canonical_workspace/\" in \"$canonical_root/\"*) ;; *) exit 126 ;; esac; fi",
      "cd -- \"$canonical_workspace\"",
      launch_script
    ]
    |> Enum.join(" && ")
  end

  defp launch_script(command, args, prompt_bytes, mcp_bytes, tracker_binding, local_temp_dir, remote_stderr_file) do
    argv = Enum.map_join(args, " ", &shell_argument/1)

    [
      "set -u",
      "umask 077",
      "prompt_file=''",
      "mcp_file=''",
      "agent_pid=''",
      process_tree_command(),
      cleanup_command(),
      "trap cleanup EXIT",
      "trap 'terminate_agent; exit 129' HUP INT TERM",
      temporary_file_setup(local_temp_dir, mcp_bytes, remote_stderr_file),
      nested_environment_unset_command(),
      maybe_read_mcp_config(mcp_bytes),
      "dd bs=1 count=#{prompt_bytes} of=\"$prompt_file\" 2>/dev/null",
      tracker_secret_unset_command(tracker_binding),
      ~s|{ set +e; SYMPHONY_CLAUDE_PROMPT_FILE="$prompt_file" SYMPHONY_CLAUDE_STDERR_FILE="$stderr_file" #{command} #{argv} < "$prompt_file" 2> "$stderr_file" & agent_pid=$!; wait "$agent_pid"; status=$?; agent_pid=''; printf '\n'; exit "$status"; }|
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp framed_input(mcp_config, prompt), do: (inline_mcp_payload(mcp_config) || "") <> prompt

  defp mcp_config_bytes(mcp_config), do: mcp_config |> inline_mcp_payload() |> byte_size_or_zero()

  defp inline_mcp_payload(value) when is_map(value), do: Jason.encode!(value)

  defp inline_mcp_payload(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> value
      _ -> nil
    end
  end

  defp inline_mcp_payload(_value), do: nil

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp maybe_create_mcp_file(0), do: nil

  defp maybe_create_mcp_file(_mcp_bytes) do
    ~s|mcp_file=$(mktemp "${TMPDIR:-/tmp}/symphony-claude-mcp.XXXXXX")|
  end

  defp temporary_file_setup(nil, mcp_bytes, remote_stderr_ref) when is_binary(remote_stderr_ref) do
    [
      maybe_create_mcp_file(mcp_bytes),
      ~s|prompt_file=$(mktemp "${TMPDIR:-/tmp}/symphony-claude-prompt.XXXXXX")|,
      ~s|stderr_file=$(mktemp "${TMPDIR:-/tmp}/#{remote_stderr_ref}.XXXXXX")|
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp temporary_file_setup(local_temp_dir, mcp_bytes, _remote_stderr_ref) when is_binary(local_temp_dir) do
    prompt_path = Path.join(local_temp_dir, "prompt")
    mcp_path = if mcp_bytes > 0, do: Path.join(local_temp_dir, "mcp"), else: ""
    stderr_path = Path.join(local_temp_dir, "stderr")

    "prompt_file=#{shell_escape(prompt_path)} && " <>
      "mcp_file=#{shell_escape(mcp_path)} && " <>
      "stderr_file=#{shell_escape(stderr_path)}"
  end

  defp maybe_read_mcp_config(0), do: nil

  defp maybe_read_mcp_config(mcp_bytes) do
    ~s|dd bs=1 count=#{mcp_bytes} of="$mcp_file" 2>/dev/null|
  end

  @doc false
  @spec process_tree_command() :: String.t()
  def process_tree_command do
    ~S"""
    child_pids() { local tree_parent="$1"; local tree_output tree_status tree_child tree_ppid tree_rest; if command -v pgrep >/dev/null 2>&1; then tree_output=$(pgrep -P "$tree_parent" 2>/dev/null); tree_status=$?; if [ "$tree_status" -eq 0 ]; then [ -z "$tree_output" ] || printf '%s\n' "$tree_output"; return 0; elif [ "$tree_status" -eq 1 ]; then return 0; fi; fi; if command -v ps >/dev/null 2>&1; then ps -e -o pid= -o ppid= 2>/dev/null | while read -r tree_child tree_ppid tree_rest; do [ "$tree_ppid" = "$tree_parent" ] && printf '%s\n' "$tree_child"; done; fi; }; collect_tree_pids() { local tree_pid="$1"; local tree_child; for tree_child in $(child_pids "$tree_pid"); do collect_tree_pids "$tree_child"; done; printf '%s\n' "$tree_pid"; }; kill_tree() { local tree_signal="$1"; shift; local tree_pid; for tree_pid in "$@"; do kill "-$tree_signal" "$tree_pid" 2>/dev/null || true; done; }; terminate_agent() { local tree_pids tree_pid; [ -z "$agent_pid" ] && return 0; tree_pids=$(collect_tree_pids "$agent_pid"); kill_tree TERM $tree_pids; sleep 0.25; for tree_pid in $tree_pids; do if kill -0 "$tree_pid" 2>/dev/null; then kill -KILL "$tree_pid" 2>/dev/null || true; fi; done; agent_pid=''; }
    """
    |> String.trim()
  end

  defp cleanup_command do
    ~s/cleanup() { terminate_agent; [ -z "$prompt_file" ] || rm -f -- "$prompt_file"; [ -z "$mcp_file" ] || rm -f -- "$mcp_file"; }/
  end

  defp shell_argument(@mcp_config_file_placeholder), do: ~s|"$mcp_file"|
  defp shell_argument(value), do: shell_escape(value)

  defp tracker_secret_port_env(tracker_binding) do
    tracker_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp nested_marker_port_env do
    Enum.map(@nested_environment_marker_names, fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(tracker_binding) do
    names = tracker_binding.secret_environment_names |> valid_environment_names()
    "unset " <> Enum.join(names, " ")
  end

  defp nested_environment_unset_command do
    "unset " <> Enum.join(@nested_environment_marker_names, " ")
  end

  defp configured_workspace_root(nil) do
    root = Config.local_workspace_root()
    {:ok, canonical_root} = PathSafety.canonicalize(root)
    canonical_root
  end

  defp configured_workspace_root(_worker_host), do: Config.settings!().workspace.root

  defp validate_session_workspace(workspace, nil) do
    configured_root = Config.local_workspace_root()
    workspace_root = configured_workspace_root(nil)

    case WorkspaceGuard.validate(workspace, nil, configured_root) do
      {:ok, safe_workspace} -> {:ok, %{workspace: safe_workspace, workspace_root: workspace_root}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_session_workspace(workspace, worker_host) when is_binary(worker_host) do
    WorkspaceGuard.validate_remote(workspace, worker_host, configured_workspace_root(worker_host))
  end

  defp validate_turn_workspace(session) do
    WorkspaceGuard.validate(session.workspace, session.worker_host, session.workspace_root)
  end

  defp session_runtime_settings(%{runtime_settings: settings}), do: settings

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp receive_stream(port, on_message, metadata, timeout_ms, pending_line, result) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, pending_line, result)
  end

  defp do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, pending_line, result) do
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {:agent_cancel, reason} ->
        error =
          Error.new(:cancelled, "Agent turn cancelled",
            code: reason,
            retryable?: false,
            raw: reason
          )

        emit(on_message, :turn_cancelled, Map.merge(metadata, %{error: error, payload: %{reason: reason}}))
        {:error, error}

      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)

        if byte_size(line) > @max_stream_frame_bytes do
          frame_too_large(on_message, metadata, byte_size(line))
        else
          {activity?, next_result} = handle_line(line, on_message, metadata, result)

          if terminal_stream_result?(next_result) do
            next_result
          else
            next_deadline_ms = if activity?, do: System.monotonic_time(:millisecond) + timeout_ms, else: deadline_ms
            do_receive_stream(port, on_message, metadata, timeout_ms, next_deadline_ms, "", next_result)
          end
        end

      {^port, {:data, {:noeol, chunk}}} ->
        next_pending_line = pending_line <> to_string(chunk)

        if byte_size(next_pending_line) > @max_stream_frame_bytes do
          frame_too_large(on_message, metadata, byte_size(next_pending_line))
        else
          do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, next_pending_line, result)
        end

      {^port, {:exit_status, 0}} ->
        {pending_line, result} = drain_after_exit(port, on_message, metadata, pending_line, result)
        result = finalize_pending_line(pending_line, on_message, metadata, result)
        final_stream_result(result, on_message, metadata)

      {^port, {:exit_status, status}} ->
        {pending_line, result} = drain_after_exit(port, on_message, metadata, pending_line, result)
        result = finalize_pending_line(pending_line, on_message, metadata, result)

        case result do
          {:error, %Error{}} = terminal_error ->
            terminal_error

          _ ->
            error =
              Error.new(:process_exit, "Claude Code exited with status #{status}",
                code: status,
                retryable?: retryable_exit_status?(status),
                raw: {:port_exit, status}
              )

            emit(on_message, :turn_failed, Map.merge(metadata, %{error: error, payload: %{exit_status: status}}))
            {:error, error}
        end
    after
      remaining_ms ->
        error =
          Error.new(:timeout, "Claude Code stream was silent for #{timeout_ms}ms",
            code: :turn_timeout,
            retryable?: true,
            raw: :turn_timeout
          )

        emit(on_message, :turn_failed, Map.merge(metadata, %{error: error, payload: %{timeout_ms: timeout_ms}}))
        {:error, error}
    end
  end

  defp drain_after_exit(port, on_message, metadata, pending_line, result) do
    deadline_ms = System.monotonic_time(:millisecond) + @post_exit_drain_ms
    do_drain_after_exit(port, on_message, metadata, deadline_ms, pending_line, result)
  end

  defp do_drain_after_exit(port, on_message, metadata, deadline_ms, pending_line, result) do
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)

        next_result =
          if byte_size(line) > @max_stream_frame_bytes do
            frame_too_large(on_message, metadata, byte_size(line))
          else
            {_activity?, handled_result} = handle_line(line, on_message, metadata, result)
            handled_result
          end

        do_drain_after_exit(port, on_message, metadata, deadline_ms, "", next_result)

      {^port, {:data, {:noeol, chunk}}} ->
        next_pending_line = pending_line <> to_string(chunk)

        if byte_size(next_pending_line) > @max_stream_frame_bytes do
          {"", frame_too_large(on_message, metadata, byte_size(next_pending_line))}
        else
          do_drain_after_exit(port, on_message, metadata, deadline_ms, next_pending_line, result)
        end
    after
      remaining_ms -> {pending_line, result}
    end
  end

  defp finalize_pending_line("", _on_message, _metadata, result), do: result

  defp finalize_pending_line(pending_line, on_message, metadata, result) do
    {_activity?, next_result} = handle_line(pending_line, on_message, metadata, result)
    next_result
  end

  defp frame_too_large(on_message, metadata, frame_bytes) do
    error =
      Error.new(:protocol, "Claude Code stream-json frame exceeded #{@max_stream_frame_bytes} bytes",
        code: :frame_too_large,
        retryable?: false,
        raw: %{frame_bytes: frame_bytes, max_frame_bytes: @max_stream_frame_bytes}
      )

    emit(
      on_message,
      :malformed_protocol,
      Map.merge(metadata, %{error: error, payload: %{frame_bytes: frame_bytes}})
    )

    {:error, error}
  end

  defp handle_line(line, on_message, metadata, result) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        if supported_payload?(payload) do
          {true, handle_payload(payload, line, on_message, metadata, result)}
        else
          {false, result}
        end

      {:ok, payload} ->
        error =
          Error.new(:protocol, "Claude Code stream-json frame must be a JSON object",
            code: :non_object_frame,
            retryable?: false,
            raw: payload
          )

        emit(on_message, :malformed_protocol, Map.merge(metadata, %{error: error, payload: payload, raw: line}))
        {false, result || {:error, error}}

      {:error, reason} ->
        if protocol_candidate?(line) do
          error =
            Error.new(:protocol, "Malformed Claude Code stream-json frame",
              code: :malformed_json,
              retryable?: false,
              raw: %{line: line, decode_error: reason}
            )

          emit(on_message, :malformed_protocol, Map.merge(metadata, %{error: error, payload: line, raw: line}))
          {false, result || {:error, error}}
        else
          {false, result}
        end
    end
  end

  defp supported_payload?(payload) when is_map(payload) do
    Map.get(payload, "type") in [
      "result",
      "error",
      "stream_event",
      "assistant",
      "user",
      "tool_use",
      "tool_result",
      "system"
    ]
  end

  defp handle_payload(_payload, _raw, _on_message, _metadata, {:error, %Error{}} = terminal_error),
    do: terminal_error

  defp handle_payload(%{"type" => "result"} = payload, raw, on_message, metadata, _result) do
    rate_limits = claude_rate_limits(payload)

    cond do
      permission_denials(payload) != [] ->
        handle_permission_denial(payload, raw, on_message, metadata, rate_limits)

      Map.get(payload, "is_error") == true or error_result_subtype?(Map.get(payload, "subtype")) ->
        error = provider_error(payload)
        usage = claude_failure_usage(payload, metadata)

        emit(
          on_message,
          :turn_failed,
          Map.merge(metadata, %{error: error, usage: usage, rate_limits: rate_limits, payload: payload, raw: raw})
        )

        {:error, error}

      true ->
        case valid_provider_session_id(payload) do
          {:ok, provider_session_id} ->
            usage = claude_usage(payload, provider_session_id, metadata.turn_id)

            emit(
              on_message,
              :turn_completed,
              Map.merge(metadata, %{
                session_id: provider_session_id,
                usage: usage,
                rate_limits: rate_limits,
                payload: payload,
                raw: raw
              })
            )

            {:ok, provider_session_id, usage, payload}

          :error ->
            error =
              Error.new(:protocol, "Claude Code result event did not include a valid session_id",
                code: :invalid_session_id,
                retryable?: false,
                raw: payload
              )

            emit(
              on_message,
              :malformed_protocol,
              Map.merge(metadata, %{
                error: error,
                usage: claude_failure_usage(payload, metadata),
                rate_limits: rate_limits,
                payload: payload,
                raw: raw
              })
            )

            {:error, error}
        end
    end
  end

  defp handle_payload(%{"type" => "error"} = payload, raw, on_message, metadata, _result) do
    error = provider_error(payload)
    usage = claude_failure_usage(payload, metadata)
    emit(on_message, :turn_failed, Map.merge(metadata, %{error: error, usage: usage, payload: payload, raw: raw}))
    {:error, error}
  end

  defp handle_payload(%{"type" => "stream_event"} = payload, raw, on_message, metadata, result) do
    emit(on_message, :progress, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  defp handle_payload(%{"type" => "assistant"} = payload, raw, on_message, metadata, result) do
    type = if tool_activity?(payload), do: :tool_activity, else: :notification
    emit(on_message, type, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  defp handle_payload(%{"type" => type} = payload, raw, on_message, metadata, result)
       when type in ["user", "tool_use", "tool_result"] do
    emit(on_message, :tool_activity, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  defp handle_payload(payload, raw, on_message, metadata, result) do
    emit(on_message, :notification, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  defp handle_permission_denial(payload, raw, on_message, metadata, rate_limits) do
    denials = permission_denials(payload)

    approval =
      Approval.new(:tool, :required,
        request_id: {metadata.session_id, metadata.turn_id},
        auto_approved?: false,
        raw: denials
      )

    error =
      Error.new(:approval_required, "Claude Code requires tool approval",
        code: :permission_denied,
        retryable?: false,
        blocked?: true,
        raw: payload
      )

    usage = claude_failure_usage(payload, metadata)

    emit(
      on_message,
      :approval_required,
      Map.merge(metadata, %{
        approval: approval,
        error: error,
        usage: usage,
        rate_limits: rate_limits,
        payload: payload,
        raw: raw
      })
    )

    {:error, error}
  end

  defp permission_denials(payload) do
    case Map.get(payload, "permission_denials") do
      denials when is_list(denials) -> denials
      _ -> []
    end
  end

  defp error_result_subtype?(subtype) when is_binary(subtype), do: String.starts_with?(subtype, "error_")
  defp error_result_subtype?(_subtype), do: false

  defp provider_error(payload) do
    raw_error = Map.get(payload, "error") || payload
    message = provider_error_message(raw_error)
    code = provider_error_code(raw_error) || Map.get(payload, "subtype") || :provider_error
    retryable? = transient_provider_error?(code, message)

    Error.new(:provider, message, code: code, retryable?: retryable?, raw: payload)
  end

  defp provider_error_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_error_message(message) when is_binary(message), do: message
  defp provider_error_message(error), do: inspect(error)

  defp provider_error_code(%{"type" => type}) when is_binary(type), do: type
  defp provider_error_code(%{"code" => code}), do: code
  defp provider_error_code(_error), do: nil

  defp transient_provider_error?(code, message) do
    text = String.downcase("#{code} #{message}")
    Regex.match?(@transient_error_pattern, text)
  end

  defp claude_usage(payload, session_id, turn_id) do
    raw = Map.get(payload, "usage") || %{}

    Usage.delta(
      :turn,
      non_negative_integer(Map.get(raw, "input_tokens")),
      non_negative_integer(Map.get(raw, "output_tokens")),
      {:claude_result, session_id, turn_id},
      total_tokens: non_negative_integer(Map.get(raw, "total_tokens")),
      cache_read_input_tokens: non_negative_integer(Map.get(raw, "cache_read_input_tokens")),
      cache_creation_input_tokens: non_negative_integer(Map.get(raw, "cache_creation_input_tokens")),
      raw: raw
    )
  end

  defp claude_failure_usage(payload, metadata) do
    session_id =
      case valid_provider_session_id(payload) do
        {:ok, provider_session_id} -> provider_session_id
        :error -> metadata.session_id
      end

    claude_usage(payload, session_id, metadata.turn_id)
  end

  # Claude reports subscription/gateway limits as percentage windows
  # (five_hour/seven_day/spend_limit); normalize them into the remaining/limit
  # bucket shape the orchestrator and dashboard already render for Codex. The
  # raw windows stay untouched in the event payload.
  defp claude_rate_limits(payload) when is_map(payload) do
    case Map.get(payload, "rate_limits") do
      %{} = windows when map_size(windows) > 0 ->
        now = System.system_time(:second)

        %{
          "limit_id" => "claude",
          "primary" => claude_window_bucket(Map.get(windows, "five_hour"), now),
          "secondary" => claude_window_bucket(Map.get(windows, "seven_day"), now),
          "credits" => claude_spend_credits(Map.get(windows, "spend_limit"))
        }

      _ ->
        nil
    end
  end

  defp claude_window_bucket(%{} = window, now) do
    bucket =
      case Map.get(window, "used_percentage") do
        used when is_number(used) ->
          %{"remaining" => max(0, round(100 - used)), "limit" => 100}

        _ ->
          %{}
      end

    case Map.get(window, "resets_at") do
      resets_at when is_number(resets_at) ->
        Map.put(bucket, "reset_in_seconds", max(0, round(resets_at - now)))

      _ ->
        bucket
    end
  end

  defp claude_window_bucket(_window, _now), do: nil

  defp claude_spend_credits(%{} = spend) do
    limit_usd = Map.get(spend, "limit_usd")
    used_usd = Map.get(spend, "used_usd")

    if is_number(limit_usd) and is_number(used_usd) do
      balance = max(0, limit_usd - used_usd)
      %{"has_credits" => balance > 0, "unlimited" => false, "balance" => balance}
    end
  end

  defp claude_spend_credits(_spend), do: nil

  defp valid_provider_session_id(payload) do
    case Map.get(payload, "session_id") do
      session_id when is_binary(session_id) ->
        trimmed = String.trim(session_id)

        if String.match?(
             trimmed,
             ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/
           ) do
          {:ok, trimmed}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp tool_activity?(payload) do
    payload
    |> get_in(["message", "content"])
    |> case do
      content when is_list(content) -> Enum.any?(content, &(is_map(&1) and Map.get(&1, "type") == "tool_use"))
      _ -> false
    end
  end

  defp final_stream_result({:ok, _session_id, _usage, _payload} = result, _on_message, _metadata), do: result
  defp final_stream_result({:error, %Error{}} = result, _on_message, _metadata), do: result

  defp final_stream_result(nil, on_message, metadata) do
    error =
      Error.new(:protocol, "Claude Code exited without a result event",
        code: :missing_result,
        retryable?: false,
        raw: :missing_result
      )

    emit(on_message, :turn_failed, Map.merge(metadata, %{error: error, payload: %{reason: :missing_result}}))
    {:error, error}
  end

  defp terminal_stream_result?({:ok, _session_id, _usage, _payload}), do: true
  defp terminal_stream_result?({:error, %Error{}}), do: true
  defp terminal_stream_result?(_result), do: false

  defp retryable_exit_status?(status) when status in [1, 2, 64, 78, 126, 127], do: false
  defp retryable_exit_status?(_status), do: true

  defp protocol_candidate?(line) do
    line |> String.trim_leading() |> String.starts_with?(["{", "["])
  end

  defp emit(on_message, type, attrs) do
    event =
      Event.new(:claude_code, type,
        timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
        session_id: Map.get(attrs, :session_id),
        thread_id: Map.get(attrs, :thread_id),
        turn_id: Map.get(attrs, :turn_id),
        process_id: Map.get(attrs, :process_id),
        usage: Map.get(attrs, :usage),
        error: Map.get(attrs, :error),
        approval: Map.get(attrs, :approval),
        rate_limits: Map.get(attrs, :rate_limits),
        payload: Map.get(attrs, :payload),
        raw: Map.get(attrs, :raw),
        worker_host: Map.get(attrs, :worker_host)
      )

    on_message.(event)
  end

  defp create_local_temp_dir do
    path = Path.join(System.tmp_dir!(), "symphony-claude-#{uuid4()}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp stop_port_and_cleanup(port, cleanup) do
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      stop_port(port)
    after
      run_turn_cleanup(cleanup)
    end
  end

  defp run_turn_cleanup(nil), do: :ok

  defp run_turn_cleanup(local_temp_dir) when is_binary(local_temp_dir) do
    collect_local_stderr_diagnostic(Path.join(local_temp_dir, "stderr"))
    File.rm_rf(local_temp_dir)
    :ok
  end

  defp run_turn_cleanup({:remote, worker_host, remote_stderr_ref}) do
    collect_remote_stderr_diagnostic(worker_host, remote_stderr_ref)
    :ok
  end

  defp cleanup_local_temp_dir(local_temp_dir, result) do
    run_turn_cleanup(local_temp_dir)
    result
  end

  defp remote_stderr_diagnostic_ref do
    "symphony-claude-stderr-#{uuid4()}"
  end

  defp collect_local_stderr_diagnostic(path) do
    case sanitize_diagnostic_bytes(bounded_stderr_read(path), @stderr_diagnostic_bytes) do
      {:ok, summary} ->
        Logger.warning("Claude Code stderr diagnostic (local, #{byte_size(summary)} bytes): #{summary}")

      :empty ->
        :ok
    end
  end

  defp bounded_stderr_read(path) do
    case File.open(path, [:binary, :read]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @stderr_read_limit_bytes) do
            data when is_binary(data) -> data
            _ -> ""
          end
        after
          File.close(io)
        end

      {:error, _reason} ->
        ""
    end
  end

  defp collect_remote_stderr_diagnostic(worker_host, remote_stderr_ref) do
    tmpdir_glob = ~s|"${TMPDIR:-/tmp}/#{remote_stderr_ref}".*|
    fallback_glob = ~s|"/tmp/#{remote_stderr_ref}".*|

    command =
      ~s|cat #{tmpdir_glob} #{fallback_glob} 2>/dev/null; rm -f -- #{tmpdir_glob} #{fallback_glob} 2>/dev/null| <>
        "; true"

    task = Task.async(fn -> SSH.run(worker_host, command, stderr_to_stdout: true) end)

    ssh_result =
      case Task.yield(task, @stderr_read_timeout_ms) do
        {:ok, result} -> result
        _ -> bounded_stderr_read_timeout(task)
      end

    log_remote_stderr_diagnostic(worker_host, ssh_result)
  end

  @doc false
  @spec bounded_stderr_read_timeout(Task.t()) :: {:error, :stderr_read_timeout}
  def bounded_stderr_read_timeout(task) do
    _ = Task.shutdown(task, :brutal_kill)
    {:error, :stderr_read_timeout}
  end

  defp log_remote_stderr_diagnostic(worker_host, {:ok, {raw, _status}}) do
    case sanitize_diagnostic_bytes(raw, @stderr_diagnostic_bytes) do
      {:ok, summary} ->
        Logger.warning("Claude Code stderr diagnostic (#{worker_host}, #{byte_size(summary)} bytes): #{summary}")

      :empty ->
        :ok
    end
  end

  defp log_remote_stderr_diagnostic(_worker_host, _ssh_result), do: :ok

  defp sanitize_diagnostic_bytes(raw, max_bytes) when is_binary(raw) do
    sanitized =
      raw
      |> String.replace_invalid()
      |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
      |> String.replace(~r/\x1B./, "")
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      |> String.trim()
      |> mask_credential_assignments()

    cond do
      sanitized == "" -> :empty
      byte_size(sanitized) <= max_bytes -> {:ok, sanitized}
      true -> {:ok, truncated_diagnostic(sanitized, max_bytes)}
    end
  end

  defp truncated_diagnostic(sanitized, max_bytes) do
    marker = "...[truncated]"
    keep_bytes = max_bytes - byte_size(marker)

    sanitized
    |> binary_part(0, keep_bytes)
    |> trim_invalid_utf8_suffix()
    |> Kernel.<>(marker)
  end

  defp trim_invalid_utf8_suffix(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> trim_invalid_utf8_suffix()
    end
  end

  defp mask_credential_assignments(value) do
    Regex.replace(~r/(?i)\b([a-z0-9_]*(?:token|secret|api_key|apikey|password|passwd|credential|authorization|auth)[a-z0-9_]*)=("[^"]*"|'[^']*'|[^\s]+)/, value, "\\1=<redacted>")
  end

  @doc false
  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          terminate_port_process(port)
          await_port_exit(port, 500)
        after
          close_port(port)
        end
    end
  end

  defp terminate_port_process(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> terminate_process_tree(os_pid)
      _ -> :ok
    end
  end

  defp terminate_process_tree(os_pid) do
    process_ids = descendant_process_ids(os_pid) ++ [os_pid]
    signal_processes(process_ids, "TERM")
    await_processes_exit(process_ids, @termination_grace_ms)
    signal_processes(Enum.filter(process_ids, &os_process_alive?/1), "KILL")
    :ok
  end

  defp descendant_process_ids(os_pid) do
    os_pid
    |> child_process_ids()
    |> Enum.flat_map(fn child_pid -> descendant_process_ids(child_pid) ++ [child_pid] end)
  end

  defp child_process_ids(os_pid) do
    case System.find_executable("pgrep") do
      nil ->
        find_child_process_ids_with_ps(os_pid)

      executable ->
        case find_child_process_ids(executable, os_pid) do
          {:ok, process_ids} -> process_ids
          {:error, 1} -> []
          {:error, _status} -> find_child_process_ids_with_ps(os_pid)
        end
    end
  end

  defp find_child_process_ids(executable, os_pid) do
    find_process_ids(executable, ["-P", Integer.to_string(os_pid)], &parse_pgrep_process_ids/1)
  end

  defp find_child_process_ids_with_ps(os_pid) do
    case System.find_executable("ps") do
      nil ->
        []

      executable ->
        case find_process_ids(executable, ["-e", "-o", "pid=", "-o", "ppid="], &parse_ps_process_ids(&1, os_pid)) do
          {:ok, process_ids} -> process_ids
          {:error, _status} -> []
        end
    end
  end

  defp find_process_ids(executable, args, parser) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parser.(output)}

      {_output, status} ->
        {:error, status}
    end
  end

  defp parse_pgrep_process_ids(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&Integer.parse/1)
    |> Enum.flat_map(&parsed_process_id/1)
  end

  defp parse_ps_process_ids(output, os_pid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
        [{pid, ""}, {^os_pid, ""} | _rest] -> [pid]
        _parsed -> []
      end
    end)
  end

  defp parsed_process_id({pid, ""}), do: [pid]
  defp parsed_process_id(_parsed), do: []

  defp signal_processes([], _signal), do: :ok

  defp signal_processes(process_ids, signal) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        Enum.each(process_ids, fn pid ->
          _ = System.cmd(executable, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
        end)
    end
  end

  defp await_processes_exit(process_ids, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_processes_exit(process_ids, deadline_ms)
  end

  defp do_await_processes_exit(process_ids, deadline_ms) do
    remaining = Enum.filter(process_ids, &os_process_alive?/1)

    cond do
      remaining == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        :ok

      true ->
        Process.sleep(20)
        do_await_processes_exit(remaining, deadline_ms)
    end
  end

  defp os_process_alive?(pid) do
    case System.find_executable("kill") do
      nil -> false
      executable -> match?({_output, 0}, System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
    end
  end

  @doc false
  @spec close_port(term()) :: :ok
  def close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await_port_exit(port, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_port_exit(port, deadline_ms)
  end

  defp do_await_port_exit(port, deadline_ms) do
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> do_await_port_exit(port, deadline_ms)
    after
      remaining_ms -> :ok
    end
  end

  defp command_port(port, input) do
    Port.command(port, input)
    :ok
  rescue
    ArgumentError -> {:error, closed_port_error()}
  end

  defp closed_port_error do
    Error.new(:process_exit, "Claude Code process exited before receiving turn input",
      code: :port_closed,
      retryable?: true,
      raw: :port_closed
    )
  end

  @doc false
  @spec port_process_id(port()) :: String.t() | nil
  def port_process_id(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> Integer.to_string(os_pid)
      _ -> nil
    end
  end

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host
end
