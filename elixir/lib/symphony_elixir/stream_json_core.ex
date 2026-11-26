defmodule SymphonyElixir.StreamJsonCore do
  @moduledoc """
  Provider-agnostic execution core for newline-delimited `stream-json` CLI backends.

  Owns the mechanics shared by every stream-json provider: port spawn (local/SSH),
  the stdin prompt-file launch script, the receive/drain loop with stall and frame
  limits, process-tree cleanup, bounded stderr diagnostics, and secret stripping.
  Provider-specific interpretation (flags, event dialect, usage/error extraction,
  native env markers) is supplied by a `Dialect` module, so adding a provider is a
  thin dialect over this core rather than a rewritten execution loop.
  """

  defmodule Dialect do
    @moduledoc """
    Provider-specific seams consumed by `StreamJsonCore`. The backend contract
    (`AgentServer`) stays above this; the dialect only describes how one CLI speaks
    stream-json and how its environment is prepared.
    """

    @callback backend_name() :: atom()
    @callback display_name() :: String.t()
    @callback temp_prefix() :: String.t()
    @callback nested_marker_names() :: [String.t()]
    @callback prompt_env_name() :: String.t()
    @callback stderr_env_name() :: String.t()
    @callback mcp_config_placeholder() :: String.t()
    @callback usage_identity_tag() :: atom()
    @callback rate_limits(map()) :: map() | nil
    @callback supported_payload?(map()) :: boolean()
    @callback handle_payload(
                payload :: map(),
                raw :: String.t(),
                on_message :: function(),
                metadata :: map(),
                result :: term()
              ) :: term()
  end

  require Logger

  alias SymphonyElixir.AgentServer.{Error, Event}
  alias SymphonyElixir.SSH

  @max_stream_frame_bytes 10_485_760
  @port_line_bytes @max_stream_frame_bytes + 1
  @post_exit_drain_ms 25
  @termination_grace_ms 250
  @stderr_diagnostic_bytes 2_048
  @stderr_read_limit_bytes 65_536
  @stderr_read_timeout_ms 2_000

  @doc """
  Emit a normalized backend event tagged with the dialect's backend name.
  """
  @spec emit(function(), atom(), atom(), map()) :: term()
  def emit(on_message, backend, type, attrs) do
    event =
      Event.new(backend, type,
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

  @spec start_port(map(), map(), [String.t()], non_neg_integer(), non_neg_integer(), module()) ::
          {:ok, port(), term()} | {:error, term()}
  def start_port(session, settings, args, prompt_bytes, mcp_bytes, dialect) do
    case session.worker_host do
      nil ->
        local_temp_dir = create_local_temp_dir(dialect)

        launch_script =
          launch_script(
            settings.command,
            args,
            prompt_bytes,
            mcp_bytes,
            session.tracker_binding,
            local_temp_dir,
            nil,
            dialect
          )

        case start_local_port(session.workspace, launch_script, session.tracker_binding, dialect) do
          {:ok, port} -> {:ok, port, local_temp_dir}
          {:error, _reason} = error -> cleanup_local_temp_dir(local_temp_dir, error, dialect)
        end

      worker_host ->
        remote_stderr_ref = remote_stderr_diagnostic_ref(dialect)

        launch_script =
          launch_script(
            settings.command,
            args,
            prompt_bytes,
            mcp_bytes,
            session.tracker_binding,
            nil,
            remote_stderr_ref,
            dialect
          )

        case start_remote_port(session, worker_host, launch_script) do
          {:ok, port} -> {:ok, port, {:remote, worker_host, remote_stderr_ref}}
          {:error, _reason} = error -> cleanup_local_temp_dir(nil, error, dialect)
        end
    end
  end

  defp start_local_port(workspace, launch_script, tracker_binding, dialect) do
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
              env: nested_marker_port_env(dialect) ++ tracker_secret_port_env(tracker_binding),
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

  defp launch_script(command, args, prompt_bytes, mcp_bytes, tracker_binding, local_temp_dir, remote_stderr_file, dialect) do
    argv = Enum.map_join(args, " ", &shell_argument(&1, dialect))

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
      temporary_file_setup(local_temp_dir, mcp_bytes, remote_stderr_file, dialect),
      nested_environment_unset_command(dialect),
      maybe_read_mcp_config(mcp_bytes),
      "dd bs=1 count=#{prompt_bytes} of=\"$prompt_file\" 2>/dev/null",
      tracker_secret_unset_command(tracker_binding),
      ~s|{ set +e; #{dialect.prompt_env_name()}="$prompt_file" #{dialect.stderr_env_name()}="$stderr_file" #{command} #{argv} < "$prompt_file" 2> "$stderr_file" & agent_pid=$!; wait "$agent_pid"; status=$?; agent_pid=''; printf '\n'; exit "$status"; }|
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  @spec framed_input(term(), String.t()) :: String.t()
  def framed_input(mcp_config, prompt), do: (inline_mcp_payload(mcp_config) || "") <> prompt

  @spec mcp_config_bytes(term()) :: non_neg_integer()
  def mcp_config_bytes(mcp_config), do: mcp_config |> inline_mcp_payload() |> byte_size_or_zero()

  @doc false
  @spec inline_mcp_payload(term()) :: String.t() | nil
  def inline_mcp_payload(value) when is_map(value), do: Jason.encode!(value)

  def inline_mcp_payload(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> value
      _ -> nil
    end
  end

  def inline_mcp_payload(_value), do: nil

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp maybe_create_mcp_file(0, _dialect), do: nil

  defp maybe_create_mcp_file(_mcp_bytes, dialect) do
    ~s|mcp_file=$(mktemp "${TMPDIR:-/tmp}/#{dialect.temp_prefix()}-mcp.XXXXXX")|
  end

  defp temporary_file_setup(nil, mcp_bytes, remote_stderr_ref, dialect) when is_binary(remote_stderr_ref) do
    [
      maybe_create_mcp_file(mcp_bytes, dialect),
      ~s|prompt_file=$(mktemp "${TMPDIR:-/tmp}/#{dialect.temp_prefix()}-prompt.XXXXXX")|,
      ~s|stderr_file=$(mktemp "${TMPDIR:-/tmp}/#{remote_stderr_ref}.XXXXXX")|
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp temporary_file_setup(local_temp_dir, mcp_bytes, _remote_stderr_ref, _dialect) when is_binary(local_temp_dir) do
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

  defp shell_argument(value, dialect) do
    if value == dialect.mcp_config_placeholder(), do: ~s|"$mcp_file"|, else: shell_escape(value)
  end

  defp tracker_secret_port_env(tracker_binding) do
    tracker_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp nested_marker_port_env(dialect) do
    Enum.map(dialect.nested_marker_names(), fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(tracker_binding) do
    names = tracker_binding.secret_environment_names |> valid_environment_names()
    "unset " <> Enum.join(names, " ")
  end

  defp nested_environment_unset_command(dialect) do
    "unset " <> Enum.join(dialect.nested_marker_names(), " ")
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  @spec receive_stream(port(), function(), map(), non_neg_integer(), String.t(), term(), module()) :: term()
  def receive_stream(port, on_message, metadata, timeout_ms, pending_line, result, dialect) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, pending_line, result, dialect)
  end

  defp do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, pending_line, result, dialect) do
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {:agent_cancel, reason} ->
        error =
          Error.new(:cancelled, "Agent turn cancelled",
            code: reason,
            retryable?: false,
            raw: reason
          )

        emit(on_message, dialect.backend_name(), :turn_cancelled, Map.merge(metadata, %{error: error, payload: %{reason: reason}}))
        {:error, error}

      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)

        if byte_size(line) > @max_stream_frame_bytes do
          frame_too_large(on_message, metadata, byte_size(line), dialect)
        else
          {activity?, next_result} = handle_line(line, on_message, metadata, result, dialect)

          if terminal_stream_result?(next_result) do
            next_result
          else
            next_deadline_ms = if activity?, do: System.monotonic_time(:millisecond) + timeout_ms, else: deadline_ms
            do_receive_stream(port, on_message, metadata, timeout_ms, next_deadline_ms, "", next_result, dialect)
          end
        end

      {^port, {:data, {:noeol, chunk}}} ->
        next_pending_line = pending_line <> to_string(chunk)

        if byte_size(next_pending_line) > @max_stream_frame_bytes do
          frame_too_large(on_message, metadata, byte_size(next_pending_line), dialect)
        else
          do_receive_stream(port, on_message, metadata, timeout_ms, deadline_ms, next_pending_line, result, dialect)
        end

      {^port, {:exit_status, 0}} ->
        {pending_line, result} = drain_after_exit(port, on_message, metadata, pending_line, result, dialect)
        result = finalize_pending_line(pending_line, on_message, metadata, result, dialect)
        final_stream_result(result, on_message, metadata, dialect)

      {^port, {:exit_status, status}} ->
        {pending_line, result} = drain_after_exit(port, on_message, metadata, pending_line, result, dialect)
        result = finalize_pending_line(pending_line, on_message, metadata, result, dialect)

        case result do
          {:error, %Error{}} = terminal_error ->
            terminal_error

          _ ->
            error =
              Error.new(:process_exit, "#{dialect.display_name()} exited with status #{status}",
                code: status,
                retryable?: retryable_exit_status?(status),
                raw: {:port_exit, status}
              )

            emit(on_message, dialect.backend_name(), :turn_failed, Map.merge(metadata, %{error: error, payload: %{exit_status: status}}))
            {:error, error}
        end
    after
      remaining_ms ->
        error =
          Error.new(:timeout, "#{dialect.display_name()} stream was silent for #{timeout_ms}ms",
            code: :turn_timeout,
            retryable?: true,
            raw: :turn_timeout
          )

        emit(on_message, dialect.backend_name(), :turn_failed, Map.merge(metadata, %{error: error, payload: %{timeout_ms: timeout_ms}}))
        {:error, error}
    end
  end

  defp drain_after_exit(port, on_message, metadata, pending_line, result, dialect) do
    deadline_ms = System.monotonic_time(:millisecond) + @post_exit_drain_ms
    do_drain_after_exit(port, on_message, metadata, deadline_ms, pending_line, result, dialect)
  end

  defp do_drain_after_exit(port, on_message, metadata, deadline_ms, pending_line, result, dialect) do
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)

        next_result =
          if byte_size(line) > @max_stream_frame_bytes do
            frame_too_large(on_message, metadata, byte_size(line), dialect)
          else
            {_activity?, handled_result} = handle_line(line, on_message, metadata, result, dialect)
            handled_result
          end

        do_drain_after_exit(port, on_message, metadata, deadline_ms, "", next_result, dialect)

      {^port, {:data, {:noeol, chunk}}} ->
        next_pending_line = pending_line <> to_string(chunk)

        if byte_size(next_pending_line) > @max_stream_frame_bytes do
          {"", frame_too_large(on_message, metadata, byte_size(next_pending_line), dialect)}
        else
          do_drain_after_exit(port, on_message, metadata, deadline_ms, next_pending_line, result, dialect)
        end
    after
      remaining_ms -> {pending_line, result}
    end
  end

  defp finalize_pending_line("", _on_message, _metadata, result, _dialect), do: result

  defp finalize_pending_line(pending_line, on_message, metadata, result, dialect) do
    {_activity?, next_result} = handle_line(pending_line, on_message, metadata, result, dialect)
    next_result
  end

  defp frame_too_large(on_message, metadata, frame_bytes, dialect) do
    error =
      Error.new(:protocol, "#{dialect.display_name()} stream-json frame exceeded #{@max_stream_frame_bytes} bytes",
        code: :frame_too_large,
        retryable?: false,
        raw: %{frame_bytes: frame_bytes, max_frame_bytes: @max_stream_frame_bytes}
      )

    emit(
      on_message,
      dialect.backend_name(),
      :malformed_protocol,
      Map.merge(metadata, %{error: error, payload: %{frame_bytes: frame_bytes}})
    )

    {:error, error}
  end

  defp handle_line(line, on_message, metadata, result, dialect) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        if dialect.supported_payload?(payload) do
          {true, dialect.handle_payload(payload, line, on_message, metadata, result)}
        else
          {false, result}
        end

      {:ok, payload} ->
        error =
          Error.new(:protocol, "#{dialect.display_name()} stream-json frame must be a JSON object",
            code: :non_object_frame,
            retryable?: false,
            raw: payload
          )

        emit(on_message, dialect.backend_name(), :malformed_protocol, Map.merge(metadata, %{error: error, payload: payload, raw: line}))
        {false, result || {:error, error}}

      {:error, reason} ->
        if protocol_candidate?(line) do
          error =
            Error.new(:protocol, "Malformed #{dialect.display_name()} stream-json frame",
              code: :malformed_json,
              retryable?: false,
              raw: %{line: line, decode_error: reason}
            )

          emit(on_message, dialect.backend_name(), :malformed_protocol, Map.merge(metadata, %{error: error, payload: line, raw: line}))
          {false, result || {:error, error}}
        else
          {false, result}
        end
    end
  end

  defp final_stream_result({:ok, _session_id, _usage, _payload} = result, _on_message, _metadata, _dialect), do: result
  defp final_stream_result({:error, %Error{}} = result, _on_message, _metadata, _dialect), do: result

  defp final_stream_result(nil, on_message, metadata, dialect) do
    error =
      Error.new(:protocol, "#{dialect.display_name()} exited without a result event",
        code: :missing_result,
        retryable?: false,
        raw: :missing_result
      )

    emit(on_message, dialect.backend_name(), :turn_failed, Map.merge(metadata, %{error: error, payload: %{reason: :missing_result}}))
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

  defp create_local_temp_dir(dialect) do
    path = Path.join(System.tmp_dir!(), "#{dialect.temp_prefix()}-#{uuid4()}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  @spec stop_port_and_cleanup(port(), term(), module()) :: :ok
  def stop_port_and_cleanup(port, cleanup, dialect) do
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      stop_port(port)
    after
      run_turn_cleanup(cleanup, dialect)
    end
  end

  defp run_turn_cleanup(nil, _dialect), do: :ok

  defp run_turn_cleanup(local_temp_dir, dialect) when is_binary(local_temp_dir) do
    collect_local_stderr_diagnostic(Path.join(local_temp_dir, "stderr"), dialect)
    File.rm_rf(local_temp_dir)
    :ok
  end

  defp run_turn_cleanup({:remote, worker_host, remote_stderr_ref}, dialect) do
    collect_remote_stderr_diagnostic(worker_host, remote_stderr_ref, dialect)
    :ok
  end

  defp cleanup_local_temp_dir(local_temp_dir, result, dialect) do
    run_turn_cleanup(local_temp_dir, dialect)
    result
  end

  defp remote_stderr_diagnostic_ref(dialect) do
    "#{dialect.temp_prefix()}-stderr-#{uuid4()}"
  end

  defp collect_local_stderr_diagnostic(path, dialect) do
    case sanitize_diagnostic_bytes(bounded_stderr_read(path), @stderr_diagnostic_bytes) do
      {:ok, summary} ->
        Logger.warning("#{dialect.display_name()} stderr diagnostic (local, #{byte_size(summary)} bytes): #{summary}")

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

  defp collect_remote_stderr_diagnostic(worker_host, remote_stderr_ref, dialect) do
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

    log_remote_stderr_diagnostic(worker_host, ssh_result, dialect)
  end

  @doc false
  @spec bounded_stderr_read_timeout(Task.t()) :: {:error, :stderr_read_timeout}
  def bounded_stderr_read_timeout(task) do
    _ = Task.shutdown(task, :brutal_kill)
    {:error, :stderr_read_timeout}
  end

  defp log_remote_stderr_diagnostic(worker_host, {:ok, {raw, _status}}, dialect) do
    case sanitize_diagnostic_bytes(raw, @stderr_diagnostic_bytes) do
      {:ok, summary} ->
        Logger.warning("#{dialect.display_name()} stderr diagnostic (#{worker_host}, #{byte_size(summary)} bytes): #{summary}")

      :empty ->
        :ok
    end
  end

  defp log_remote_stderr_diagnostic(_worker_host, _ssh_result, _dialect), do: :ok

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

  @spec command_port(port(), String.t(), module()) :: :ok | {:error, Error.t()}
  def command_port(port, input, dialect) do
    Port.command(port, input)
    :ok
  rescue
    ArgumentError -> {:error, closed_port_error(dialect)}
  end

  defp closed_port_error(dialect) do
    Error.new(:process_exit, "#{dialect.display_name()} process exited before receiving turn input",
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

  @doc false
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
