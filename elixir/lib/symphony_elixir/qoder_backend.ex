defmodule SymphonyElixir.QoderBackend do
  @moduledoc """
  Qoder CLI backend using non-interactive newline-delimited `stream-json`.

  Qoder CLI emits the same event/result shape as Claude Code (verified against
  qodercli 1.1.98), so it reuses `StreamJsonCore` mechanics and
  `StreamJsonCore.Payload` interpretation. The dialect supplies Qoder-specific
  flags (kebab-case tools, snake_case permission modes, no `--verbose`),
  the `QODER_AGENT_SDK_ENTRYPOINT` nesting marker, and naming.

  Minimal closed loop (P3): spawn → stream-json → result → resume. Restricted
  Linear MCP injection is added in P4.
  """

  @behaviour SymphonyElixir.AgentServer
  @behaviour SymphonyElixir.StreamJsonCore.Dialect

  require Logger

  alias SymphonyElixir.AgentServer
  alias SymphonyElixir.AgentServer.{Error, WorkspaceGuard}
  alias SymphonyElixir.{Config, PathSafety, StreamJsonCore, Tracker}
  alias SymphonyElixir.StreamJsonCore.Payload

  @type session :: %{
          backend: :qoder,
          session_id: String.t(),
          initial_session_id: String.t(),
          resume_session_id: String.t() | nil,
          thread_id: String.t(),
          workspace: Path.t(),
          workspace_root: Path.t(),
          worker_host: String.t() | nil,
          turn_count: non_neg_integer(),
          runtime_settings: map(),
          tracker_binding: map()
        }

  @impl SymphonyElixir.AgentServer
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_session_workspace(workspace, worker_host) do
      {:ok, %{workspace: safe_workspace, workspace_root: workspace_root}} ->
        session_id = StreamJsonCore.uuid4()
        runtime_settings = Config.qoder_runtime_settings()
        tracker_binding = Tracker.bind_agent_tools()

        {:ok,
         %{
           backend: :qoder,
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

    Logger.info("Qoder turn starting for #{issue_context(issue)} session_id=#{current_session_id} turn_id=#{turn_id} worker_host=#{worker_host_for_log(session.worker_host)}")

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

                  Logger.info("Qoder turn completed for #{issue_context(issue)} session_id=#{provider_session_id} turn_id=#{base.turn_id}")

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
                  Logger.warning("Qoder turn failed for #{issue_context(issue)} turn_id=#{base.turn_id} kind=#{error.kind} code=#{inspect(error.code)}")

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
      "--setting-sources",
      "user",
      "--strict-mcp-config"
    ]
    |> add_session_args(session)
    |> maybe_add_option("--model", settings.model)
    |> maybe_add_option("--permission-mode", settings.permission_mode)
    |> maybe_add_option("--reasoning-effort", settings.reasoning_effort)
    |> add_repeated_options("--allowed-tools", settings.allowed_tools)
    |> add_repeated_options("--disallowed-tools", settings.disallowed_tools)
    |> maybe_add_option("--mcp-config", mcp_config_argument(settings.mcp_config))
  end

  defp add_session_args(args, %{resume_session_id: resume_session_id}) when is_binary(resume_session_id) do
    args ++ ["--resume", resume_session_id]
  end

  defp add_session_args(args, %{session_id: session_id}) do
    args ++ ["--session-id", session_id]
  end

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
  def backend_name, do: :qoder

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def display_name, do: "Qoder"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def temp_prefix, do: "symphony-qoder"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def nested_marker_names, do: ["QODER_AGENT_SDK_ENTRYPOINT"]

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def prompt_env_name, do: "SYMPHONY_QODER_PROMPT_FILE"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def stderr_env_name, do: "SYMPHONY_QODER_STDERR_FILE"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def mcp_config_placeholder, do: "__SYMPHONY_QODER_MCP_CONFIG_FILE__"

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def usage_identity_tag, do: :qoder_result

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def rate_limits(_payload), do: nil

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def supported_payload?(payload), do: Payload.supported_payload?(payload)

  @impl SymphonyElixir.StreamJsonCore.Dialect
  def handle_payload(payload, raw, on_message, metadata, result) do
    Payload.handle_payload(payload, raw, on_message, metadata, result, __MODULE__)
  end

  defp emit(on_message, type, attrs) do
    StreamJsonCore.emit(on_message, :qoder, type, attrs)
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

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host
end
