defmodule SymphonyElixir.ClaudeCodeBackend do
  @moduledoc """
  Claude Code CLI backend using non-interactive newline-delimited `stream-json`.

  Provider-specific dialect (flags, env markers, rate-limit shape) over the shared
  `StreamJsonCore` execution engine and `StreamJsonCore.Payload` interpretation,
  which Claude Code and Qoder CLI share (their stream-json event shapes match).
  """

  @behaviour SymphonyElixir.AgentServer
  @behaviour SymphonyElixir.StreamJsonCore.Dialect

  require Logger

  alias SymphonyElixir.AgentServer
  alias SymphonyElixir.AgentServer.{Error, WorkspaceGuard}
  alias SymphonyElixir.{Config, PathSafety, StreamJsonCore, Tracker}
  alias SymphonyElixir.StreamJsonCore.Payload

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

  @impl SymphonyElixir.AgentServer
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_session_workspace(workspace, worker_host) do
      {:ok, %{workspace: safe_workspace, workspace_root: workspace_root}} ->
        session_id = StreamJsonCore.uuid4()
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
           tracker_binding: tracker_binding,
           effort: Keyword.get(opts, :effort)
         }}

      {:error, reason} ->
        {:error, AgentServer.normalize_error(reason, :startup)}
    end
  end

  @impl SymphonyElixir.AgentServer
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

    case StreamJsonCore.TrackerMcp.prepare(session, issue, settings, current_session_id, turn_id) do
      {:ok, turn_settings, tracker_mcp_token} ->
        try do
          run_prepared_turn(session, prompt, issue, on_message, base, turn_settings)
        after
          StreamJsonCore.TrackerMcp.close(tracker_mcp_token)
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason, :startup)
        emit(on_message, :startup_failed, Map.merge(base, %{error: error, payload: reason}))
        {:error, error}
    end
  end

  defp run_prepared_turn(session, prompt, issue, on_message, base, settings) do
    args = cli_args(session, settings)
    input = StreamJsonCore.framed_input(settings.mcp_config, prompt)
    mcp_bytes = StreamJsonCore.mcp_config_bytes(settings.mcp_config)

    case StreamJsonCore.start_port(session, settings, args, byte_size(prompt), mcp_bytes, __MODULE__) do
      {:ok, port, cleanup} ->
        try do
          metadata = Map.put(base, :process_id, StreamJsonCore.port_process_id(port))
          emit(on_message, :session_started, metadata)

          case StreamJsonCore.command_port(port, input, __MODULE__) do
            :ok ->
              case StreamJsonCore.receive_stream(
                     port,
                     on_message,
                     metadata,
                     settings.turn_timeout_ms,
                     "",
                     nil,
                     __MODULE__
                   ) do
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
          StreamJsonCore.stop_port_and_cleanup(port, cleanup, __MODULE__)
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason, :startup)
        emit(on_message, :startup_failed, Map.merge(base, %{error: error, payload: reason}))
        {:error, error}
    end
  end

  @impl SymphonyElixir.AgentServer
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
    |> maybe_add_option("--effort", session.effort)
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
    if StreamJsonCore.inline_mcp_payload(value), do: mcp_config_placeholder(), else: value
  end

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def backend_name, do: :claude_code

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def display_name, do: "Claude Code"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def temp_prefix, do: "symphony-claude"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def nested_marker_names, do: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def prompt_env_name, do: "SYMPHONY_CLAUDE_PROMPT_FILE"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def stderr_env_name, do: "SYMPHONY_CLAUDE_STDERR_FILE"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def mcp_config_placeholder, do: "__SYMPHONY_CLAUDE_MCP_CONFIG_FILE__"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def usage_identity_tag, do: :claude_result

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def rate_limits(payload), do: claude_rate_limits(payload)

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def supported_payload?(payload), do: Payload.supported_payload?(payload)

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def handle_payload(payload, raw, on_message, metadata, result) do
    Payload.handle_payload(payload, raw, on_message, metadata, result, __MODULE__)
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

  defp emit(on_message, type, attrs) do
    StreamJsonCore.emit(on_message, :claude_code, type, attrs)
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

  @doc false
  @spec process_tree_command() :: String.t()
  def process_tree_command, do: StreamJsonCore.process_tree_command()

  @doc false
  @spec port_process_id(port()) :: String.t() | nil
  def port_process_id(port), do: StreamJsonCore.port_process_id(port)

  @doc false
  @spec stop_port(port()) :: :ok
  def stop_port(port), do: StreamJsonCore.stop_port(port)

  @doc false
  @spec close_port(term()) :: :ok
  def close_port(port), do: StreamJsonCore.close_port(port)

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host
end
