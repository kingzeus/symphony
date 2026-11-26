defmodule SymphonyElixir.AgentServer do
  @moduledoc """
  Shared lifecycle and runtime event contract for coding-agent backends.

  Provider protocol details remain owned by the concrete backend. The runner
  and orchestrator consume the normalized event, usage, error, and approval
  structs defined here.
  """

  defmodule Usage do
    @moduledoc "Token usage reported by a backend."

    @enforce_keys [:mode, :scope, :identity]
    defstruct mode: nil,
              scope: nil,
              input_tokens: nil,
              output_tokens: nil,
              total_tokens: nil,
              cache_read_input_tokens: nil,
              cache_creation_input_tokens: nil,
              identity: nil,
              raw: nil

    @type mode :: :absolute | :delta
    @type scope :: :thread | :turn
    @type t :: %__MODULE__{
            mode: mode(),
            scope: scope(),
            input_tokens: non_neg_integer() | nil,
            output_tokens: non_neg_integer() | nil,
            total_tokens: non_neg_integer() | nil,
            cache_read_input_tokens: non_neg_integer() | nil,
            cache_creation_input_tokens: non_neg_integer() | nil,
            identity: term(),
            raw: term()
          }

    @spec absolute(scope(), non_neg_integer() | nil, non_neg_integer() | nil, term(), keyword()) :: t()
    def absolute(scope, input_tokens, output_tokens, identity, opts \\ []) do
      new(:absolute, scope, input_tokens, output_tokens, identity, opts)
    end

    @spec delta(scope(), non_neg_integer() | nil, non_neg_integer() | nil, term(), keyword()) :: t()
    def delta(scope, input_tokens, output_tokens, identity, opts \\ []) do
      new(:delta, scope, input_tokens, output_tokens, identity, opts)
    end

    defp new(mode, scope, input_tokens, output_tokens, identity, opts) do
      total_tokens =
        case Keyword.get(opts, :total_tokens) do
          total when is_integer(total) and total >= 0 -> total
          _ -> nil
        end

      %__MODULE__{
        mode: mode,
        scope: scope,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        cache_read_input_tokens: Keyword.get(opts, :cache_read_input_tokens),
        cache_creation_input_tokens: Keyword.get(opts, :cache_creation_input_tokens),
        identity: identity,
        raw: Keyword.get(opts, :raw)
      }
    end
  end

  defmodule Error do
    @moduledoc "Typed backend error used for retry and blocked routing."

    @enforce_keys [:kind, :message, :retryable?, :blocked?]
    defstruct kind: nil,
              message: nil,
              code: nil,
              retryable?: false,
              blocked?: false,
              raw: nil

    @type t :: %__MODULE__{
            kind: atom(),
            message: String.t(),
            code: term(),
            retryable?: boolean(),
            blocked?: boolean(),
            raw: term()
          }

    @spec new(atom(), String.t(), keyword()) :: t()
    def new(kind, message, opts \\ []) when is_atom(kind) and is_binary(message) do
      %__MODULE__{
        kind: kind,
        message: message,
        code: Keyword.get(opts, :code),
        retryable?: Keyword.get(opts, :retryable?, false),
        blocked?: Keyword.get(opts, :blocked?, false),
        raw: Keyword.get(opts, :raw)
      }
    end
  end

  defmodule Approval do
    @moduledoc "Normalized approval state emitted by a backend."

    @enforce_keys [:kind, :status]
    defstruct kind: nil,
              status: nil,
              request_id: nil,
              decision: nil,
              auto_approved?: false,
              raw: nil

    @type t :: %__MODULE__{
            kind: atom(),
            status: atom(),
            request_id: term(),
            decision: term(),
            auto_approved?: boolean(),
            raw: term()
          }

    @spec new(atom(), atom(), keyword()) :: t()
    def new(kind, status, opts \\ []) when is_atom(kind) and is_atom(status) do
      %__MODULE__{
        kind: kind,
        status: status,
        request_id: Keyword.get(opts, :request_id),
        decision: Keyword.get(opts, :decision),
        auto_approved?: Keyword.get(opts, :auto_approved?, false),
        raw: Keyword.get(opts, :raw)
      }
    end
  end

  defmodule Event do
    @moduledoc "Provider-neutral event delivered to the runner and orchestrator."

    @enforce_keys [:backend, :type, :timestamp]
    defstruct backend: nil,
              type: nil,
              timestamp: nil,
              session_id: nil,
              thread_id: nil,
              turn_id: nil,
              process_id: nil,
              usage: nil,
              error: nil,
              approval: nil,
              payload: nil,
              raw: nil,
              # Compatibility aliases retained during the first migration phase.
              event: nil,
              message: nil,
              display_message: nil,
              codex_app_server_pid: nil,
              worker_host: nil,
              details: nil,
              rate_limits: nil

    @type t :: %__MODULE__{
            backend: :codex | :claude_code,
            type: atom(),
            timestamp: DateTime.t(),
            session_id: String.t() | nil,
            thread_id: String.t() | nil,
            turn_id: String.t() | nil,
            process_id: String.t() | nil,
            usage: Usage.t() | nil,
            error: Error.t() | nil,
            approval: Approval.t() | nil,
            payload: term(),
            raw: String.t() | nil,
            event: atom(),
            message: term(),
            display_message: String.t() | nil,
            codex_app_server_pid: String.t() | nil,
            worker_host: String.t() | nil,
            details: term(),
            rate_limits: term()
          }

    @spec new(:codex | :claude_code, atom(), keyword()) :: t()
    def new(backend, type, opts \\ []) when backend in [:codex, :claude_code] and is_atom(type) do
      process_id = normalize_process_id(Keyword.get(opts, :process_id))
      payload = Keyword.get(opts, :payload)

      %__MODULE__{
        backend: backend,
        type: type,
        timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
        session_id: Keyword.get(opts, :session_id),
        thread_id: Keyword.get(opts, :thread_id),
        turn_id: Keyword.get(opts, :turn_id),
        process_id: process_id,
        usage: Keyword.get(opts, :usage),
        error: Keyword.get(opts, :error),
        approval: Keyword.get(opts, :approval),
        payload: payload,
        raw: Keyword.get(opts, :raw),
        event: Keyword.get(opts, :event, type),
        message: Keyword.get(opts, :message, payload),
        display_message: Keyword.get(opts, :display_message),
        codex_app_server_pid: Keyword.get(opts, :codex_app_server_pid, process_id),
        worker_host: Keyword.get(opts, :worker_host),
        details: Keyword.get(opts, :details),
        rate_limits: Keyword.get(opts, :rate_limits)
      }
    end

    defp normalize_process_id(nil), do: nil
    defp normalize_process_id(process_id) when is_binary(process_id), do: process_id
    defp normalize_process_id(process_id) when is_integer(process_id), do: Integer.to_string(process_id)
    defp normalize_process_id(process_id) when is_list(process_id), do: to_string(process_id)
    defp normalize_process_id(process_id), do: inspect(process_id)
  end

  defmodule WorkspaceGuard do
    @moduledoc false

    alias SymphonyElixir.{Config, PathSafety, SSH}

    @spec validate(Path.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
    def validate(workspace, nil) when is_binary(workspace) do
      validate(workspace, nil, Config.local_workspace_root())
    end

    def validate(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
      validate(workspace, worker_host, Config.settings!().workspace.root)
    end

    @spec validate(Path.t(), String.t() | nil, Path.t()) :: {:ok, Path.t()} | {:error, term()}
    def validate(workspace, nil, workspace_root) when is_binary(workspace) and is_binary(workspace_root) do
      expanded_workspace = Path.expand(workspace)
      expanded_root = Path.expand(workspace_root)

      with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
           {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
        cond do
          canonical_workspace == canonical_root ->
            {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

          descendant_path?(canonical_workspace, canonical_root) ->
            {:ok, canonical_workspace}

          descendant_path?(expanded_workspace, expanded_root) ->
            {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

          true ->
            {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
        end
      else
        {:error, {:path_canonicalize_failed, path, reason}} ->
          {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
      end
    end

    def validate(workspace, worker_host, workspace_root)
        when is_binary(workspace) and is_binary(worker_host) and is_binary(workspace_root) do
      case validate_remote(workspace, worker_host, workspace_root) do
        {:ok, %{workspace: canonical_workspace}} -> {:ok, canonical_workspace}
        {:error, _reason} = error -> error
      end
    end

    @spec validate_remote(Path.t(), String.t(), Path.t()) ::
            {:ok, %{workspace: Path.t(), workspace_root: Path.t()}} | {:error, term()}
    def validate_remote(workspace, worker_host, workspace_root)
        when is_binary(workspace) and is_binary(worker_host) and is_binary(workspace_root) do
      cond do
        String.trim(workspace) == "" ->
          {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

        String.trim(workspace_root) == "" ->
          {:error, {:invalid_workspace_cwd, :empty_remote_workspace_root, worker_host}}

        String.contains?(workspace, ["\n", "\r", <<0>>]) or
            String.contains?(workspace_root, ["\n", "\r", <<0>>]) ->
          {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

        true ->
          validate_remote_paths(workspace, worker_host, workspace_root)
      end
    end

    defp validate_remote_paths(workspace, worker_host, workspace_root) do
      command = remote_validation_command(workspace, workspace_root)

      case SSH.run(worker_host, command, stderr_to_stdout: true) do
        {:ok, {output, 0}} ->
          parse_remote_validation(output, worker_host)

        {:ok, {output, status}} ->
          {:error, {:invalid_workspace_cwd, :remote_validation_failed, worker_host, status, String.slice(output, 0, 500)}}

        {:error, reason} ->
          {:error, {:invalid_workspace_cwd, :remote_validation_unavailable, worker_host, reason}}
      end
    end

    defp remote_validation_command(workspace, workspace_root) do
      [
        "set -u",
        "workspace=#{shell_escape(workspace)}",
        "workspace_root=#{shell_escape(workspace_root)}",
        ~s|case "$workspace" in "~") workspace="$HOME" ;; "~/"*) workspace="$HOME/${workspace#*/}" ;; esac|,
        ~s|case "$workspace_root" in "~") workspace_root="$HOME" ;; "~/"*) workspace_root="$HOME/${workspace_root#*/}" ;; esac|,
        "canonical_workspace=$(cd -- \"$workspace\" 2>/dev/null && pwd -P) || { printf 'workspace-unreadable\\n' >&2; exit 40; }",
        "canonical_root=$(cd -- \"$workspace_root\" 2>/dev/null && pwd -P) || { printf 'workspace-root-unreadable\\n' >&2; exit 41; }",
        "[ \"$canonical_workspace\" != \"$canonical_root\" ] || { printf 'workspace-is-root\\n' >&2; exit 42; }",
        ~s|if [ "$canonical_root" = "/" ]; then case "$canonical_workspace" in /*) ;; *) printf 'workspace-outside-root\n' >&2; exit 43 ;; esac; else case "$canonical_workspace/" in "$canonical_root/"*) ;; *) printf 'workspace-outside-root\n' >&2; exit 43 ;; esac; fi|,
        ~s|printf '__SYMPHONY_WORKSPACE__%s\n__SYMPHONY_WORKSPACE_ROOT__%s\n' "$canonical_workspace" "$canonical_root"|
      ]
      |> Enum.join(" && ")
    end

    defp parse_remote_validation(output, worker_host) do
      lines = String.split(output, "\n", trim: true)

      canonical_workspace =
        marker_value(lines, "__SYMPHONY_WORKSPACE__")

      canonical_root =
        marker_value(lines, "__SYMPHONY_WORKSPACE_ROOT__")

      if is_binary(canonical_workspace) and canonical_workspace != "" and is_binary(canonical_root) and
           canonical_root != "" do
        {:ok, %{workspace: canonical_workspace, workspace_root: canonical_root}}
      else
        {:error, {:invalid_workspace_cwd, :remote_validation_malformed, worker_host, String.slice(output, 0, 500)}}
      end
    end

    defp marker_value(lines, marker) do
      Enum.find_value(lines, fn line ->
        if String.starts_with?(line, marker), do: String.replace_prefix(line, marker, "")
      end)
    end

    defp descendant_path?(path, "/"), do: String.starts_with?(path, "/") and path != "/"
    defp descendant_path?(path, root), do: String.starts_with?(path <> "/", root <> "/") and path != root

    defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, Error.t()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback stop_session(session()) :: :ok

  @backends %{
    codex: SymphonyElixir.Codex.AppServer,
    claude_code: SymphonyElixir.ClaudeCodeBackend
  }

  @doc """
  Registered backend names. Adding a provider is a matter of extending this
  registry (plus its config schema); the contract and consumers stay unchanged.
  """
  @spec backend_names() :: [atom()]
  def backend_names, do: Map.keys(@backends)

  @spec backend_module(atom() | String.t()) :: module()
  def backend_module(name) when is_atom(name) do
    case Map.fetch(@backends, name) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unknown agent backend: #{inspect(name)}"
    end
  end

  def backend_module(name) when is_binary(name) do
    module =
      Enum.find_value(@backends, fn {key, backend_module} ->
        if Atom.to_string(key) == name, do: backend_module
      end)

    case module do
      nil -> raise ArgumentError, "unknown agent backend: #{inspect(name)}"
      module -> module
    end
  end

  @spec backend_name(module()) :: :codex | :claude_code
  def backend_name(module) do
    Enum.find_value(@backends, :codex, fn {name, backend_module} ->
      if backend_module == module, do: name
    end)
  end

  @spec normalize_event(:codex | :claude_code, Event.t() | map()) :: Event.t()
  def normalize_event(_backend, %Event{} = event), do: event

  def normalize_event(backend, update) when is_map(update) do
    contract_type = event_field(update, :type)
    legacy_event = event_field(update, :event, contract_type || :notification)
    normalized_type = normalized_event_type(contract_type || legacy_event)
    payload = event_field(update, :payload)

    Event.new(backend, normalized_type,
      timestamp: normalized_timestamp(event_field(update, :timestamp, DateTime.utc_now())),
      session_id: event_field(update, :session_id),
      thread_id: event_field(update, :thread_id),
      turn_id: event_field(update, :turn_id),
      process_id: event_field(update, :process_id) || event_field(update, :codex_app_server_pid),
      usage: normalized_usage(backend, update),
      error: normalized_event_error(normalized_type, update),
      approval: normalized_approval(normalized_type, legacy_event, update),
      payload: payload,
      raw: event_field(update, :raw),
      event: legacy_event,
      message: event_field(update, :message),
      display_message: event_field(update, :display_message),
      worker_host: event_field(update, :worker_host),
      details: event_field(update, :details),
      rate_limits: event_field(update, :rate_limits)
    )
  end

  defp event_field(update, key, default \\ nil) do
    case Map.fetch(update, key) do
      {:ok, value} -> value
      :error -> Map.get(update, Atom.to_string(key), default)
    end
  end

  defp normalized_event_type(:approval_auto_approved), do: :approval_resolved
  defp normalized_event_type(:turn_input_required), do: :input_required
  defp normalized_event_type(:malformed), do: :malformed_protocol
  defp normalized_event_type(:turn_ended_with_error), do: :turn_failed
  defp normalized_event_type(:other_message), do: :notification

  defp normalized_event_type(event)
       when event in [
              "session_started",
              "notification",
              "progress",
              "tool_activity",
              "approval_required",
              "approval_resolved",
              "input_required",
              "turn_completed",
              "turn_failed",
              "turn_cancelled",
              "startup_failed",
              "malformed_protocol"
            ],
       do: String.to_existing_atom(event)

  defp normalized_event_type("approval_auto_approved"), do: :approval_resolved
  defp normalized_event_type("turn_input_required"), do: :input_required
  defp normalized_event_type("malformed"), do: :malformed_protocol
  defp normalized_event_type("turn_ended_with_error"), do: :turn_failed
  defp normalized_event_type("other_message"), do: :notification

  defp normalized_event_type(event)
       when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call],
       do: :tool_activity

  defp normalized_event_type(event) when is_atom(event), do: event
  defp normalized_event_type(_event), do: :notification

  defp normalized_timestamp(%DateTime{} = timestamp), do: timestamp

  defp normalized_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _ -> DateTime.utc_now()
    end
  end

  defp normalized_timestamp(_timestamp), do: DateTime.utc_now()

  defp normalized_usage(backend, update) do
    case event_field(update, :usage) do
      %Usage{} = usage -> usage
      usage when is_map(usage) -> normalized_typed_usage(usage) || normalized_backend_usage(backend, update, usage)
      usage -> normalized_backend_usage(backend, update, usage)
    end
  end

  defp normalized_backend_usage(:codex, update, usage), do: normalized_codex_usage(update, usage)
  defp normalized_backend_usage(_backend, _update, _usage), do: nil

  defp normalized_typed_usage(usage) do
    mode = normalized_usage_mode(event_field(usage, :mode))
    scope = normalized_usage_scope(event_field(usage, :scope))
    identity = event_field(usage, :identity)

    if mode && scope && not is_nil(identity) do
      new_typed_usage(mode, scope, identity, usage)
    end
  end

  defp new_typed_usage(mode, scope, identity, usage) do
    input = token_integer(usage, [:input_tokens, "input_tokens"])
    output = token_integer(usage, [:output_tokens, "output_tokens"])

    opts = [
      total_tokens: token_integer(usage, [:total_tokens, "total_tokens"]),
      cache_read_input_tokens: token_integer(usage, [:cache_read_input_tokens, "cache_read_input_tokens"]),
      cache_creation_input_tokens: token_integer(usage, [:cache_creation_input_tokens, "cache_creation_input_tokens"]),
      raw: event_field(usage, :raw, usage)
    ]

    case mode do
      :absolute -> Usage.absolute(scope, input, output, identity, opts)
      :delta -> Usage.delta(scope, input, output, identity, opts)
    end
  end

  defp normalized_usage_mode(:absolute), do: :absolute
  defp normalized_usage_mode(:delta), do: :delta
  defp normalized_usage_mode("absolute"), do: :absolute
  defp normalized_usage_mode("delta"), do: :delta
  defp normalized_usage_mode(_mode), do: nil

  defp normalized_usage_scope(:thread), do: :thread
  defp normalized_usage_scope(:turn), do: :turn
  defp normalized_usage_scope("thread"), do: :thread
  defp normalized_usage_scope("turn"), do: :turn
  defp normalized_usage_scope(_scope), do: nil

  defp normalized_codex_usage(update, _usage) do
    case codex_usage_source(update) do
      {:absolute, source, raw} ->
        input = token_integer(raw, [:input_tokens, :prompt_tokens, :inputTokens, "input_tokens", "prompt_tokens", "inputTokens"])
        output = token_integer(raw, [:output_tokens, :completion_tokens, :outputTokens, "output_tokens", "completion_tokens", "outputTokens"])
        total = token_integer(raw, [:total_tokens, :total, :totalTokens, "total_tokens", "total", "totalTokens"])

        if Enum.any?([input, output, total], &is_integer/1) do
          Usage.absolute(
            :thread,
            input,
            output,
            {:codex_usage, source, event_field(update, :thread_id), input, output, total},
            total_tokens: total,
            raw: raw
          )
        end

      _ ->
        nil
    end
  end

  defp codex_usage_source(update) do
    payload = event_field(update, :payload)

    [
      {:total_token_usage, nested_field(payload, [:params, :msg, :payload, :info, :total_token_usage])},
      {:total_token_usage, nested_field(payload, [:params, :msg, :info, :total_token_usage])},
      {:thread_token_usage_total, thread_token_usage_total(payload)},
      {:turn_completed, turn_completed_usage(update, payload)}
    ]
    |> Enum.find_value(fn
      {source, raw} when is_map(raw) -> if token_map?(raw), do: {:absolute, source, raw}
      _candidate -> nil
    end)
  end

  defp thread_token_usage_total(payload) do
    if payload_method(payload) in ["thread/tokenUsage/updated", :thread_token_usage_updated] do
      nested_field(payload, [:params, :tokenUsage, :total])
    end
  end

  defp turn_completed_usage(update, payload) do
    if normalized_event_type(event_field(update, :event)) == :turn_completed or
         payload_method(payload) in ["turn/completed", :turn_completed] do
      event_field(update, :usage) ||
        nested_field(payload, [:usage]) ||
        nested_field(payload, [:params, :usage])
    end
  end

  defp payload_method(payload) when is_map(payload), do: event_field(payload, :method)
  defp payload_method(_payload), do: nil

  defp nested_field(value, []), do: value

  defp nested_field(map, [key | rest]) when is_map(map) and is_atom(key) do
    map
    |> event_field(key)
    |> nested_field(rest)
  end

  defp nested_field(_value, _path), do: nil

  defp token_map?(map) when is_map(map) do
    Enum.any?(
      [
        :input_tokens,
        :prompt_tokens,
        :inputTokens,
        :output_tokens,
        :completion_tokens,
        :outputTokens,
        :total_tokens,
        :totalTokens,
        "input_tokens",
        "prompt_tokens",
        "inputTokens",
        "output_tokens",
        "completion_tokens",
        "outputTokens",
        "total_tokens",
        "totalTokens"
      ],
      &(is_integer(Map.get(map, &1)) or is_binary(Map.get(map, &1)))
    )
  end

  defp token_integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        value when is_binary(value) -> parse_non_negative_integer(value)
        _ -> nil
      end
    end)
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp normalized_event_error(event, update) do
    case event_field(update, :error) do
      %Error{} = error -> error
      error when is_map(error) -> normalized_typed_error(error)
      _ -> normalized_event_error_from_type(event, update)
    end
  end

  defp normalized_typed_error(error) do
    Error.new(
      normalized_contract_atom(event_field(error, :kind), :provider),
      normalized_contract_message(event_field(error, :message)),
      code: event_field(error, :code),
      retryable?: event_field(error, :retryable?, false) == true,
      blocked?: event_field(error, :blocked?, false) == true,
      raw: event_field(error, :raw)
    )
  end

  defp normalized_event_error_from_type(event, update) when event in [:input_required, :approval_required] do
    normalize_error({event_error_tuple(event), event_field(update, :payload)}, :provider)
  end

  defp normalized_event_error_from_type(:turn_failed, update) do
    normalize_error({:turn_failed, event_field(update, :reason) || event_field(update, :payload)})
  end

  defp normalized_event_error_from_type(:turn_cancelled, update) do
    normalize_error({:turn_cancelled, event_field(update, :reason) || event_field(update, :payload)})
  end

  defp normalized_event_error_from_type(:startup_failed, update) do
    normalize_error(event_field(update, :reason) || update, :startup)
  end

  defp normalized_event_error_from_type(:malformed_protocol, update), do: normalize_error(update, :protocol)
  defp normalized_event_error_from_type(_event, _update), do: nil

  defp event_error_tuple(:input_required), do: :turn_input_required
  defp event_error_tuple(:approval_required), do: :approval_required

  defp normalized_approval(event, legacy_event, update) do
    case event_field(update, :approval) do
      %Approval{} = approval -> approval
      approval when is_map(approval) -> normalized_typed_approval(event, approval)
      _ -> normalized_approval_from_type(event, legacy_event, update)
    end
  end

  defp normalized_typed_approval(event, approval) do
    default_status = if event == :approval_required, do: :required, else: :resolved

    Approval.new(
      normalized_contract_atom(event_field(approval, :kind), :tool),
      normalized_contract_atom(event_field(approval, :status), default_status),
      request_id: event_field(approval, :request_id),
      decision: event_field(approval, :decision),
      auto_approved?: event_field(approval, :auto_approved?, false) == true,
      raw: event_field(approval, :raw)
    )
  end

  @contract_atoms %{
    "startup" => :startup,
    "timeout" => :timeout,
    "process_exit" => :process_exit,
    "provider" => :provider,
    "protocol" => :protocol,
    "cancelled" => :cancelled,
    "input_required" => :input_required,
    "approval_required" => :approval_required,
    "file" => :file,
    "command" => :command,
    "tool" => :tool,
    "mcp" => :mcp,
    "required" => :required,
    "resolved" => :resolved,
    "approved" => :approved,
    "denied" => :denied
  }

  defp normalized_contract_atom(value, _default) when is_atom(value), do: value
  defp normalized_contract_atom(value, default) when is_binary(value), do: Map.get(@contract_atoms, value, default)
  defp normalized_contract_atom(_value, default), do: default

  defp normalized_contract_message(message) when is_binary(message), do: message
  defp normalized_contract_message(message), do: inspect(message)

  defp normalized_approval_from_type(event, legacy_event, update)
       when event in [:approval_required, :approval_resolved] do
    payload = event_field(update, :payload) || %{}
    method = Map.get(payload, "method") || Map.get(payload, :method)
    auto_approved? = legacy_event in [:approval_auto_approved, "approval_auto_approved"]

    Approval.new(approval_kind(method), if(event == :approval_required, do: :required, else: :resolved),
      request_id: Map.get(payload, "id") || Map.get(payload, :id),
      decision: event_field(update, :decision),
      auto_approved?: auto_approved?,
      raw: payload
    )
  end

  defp normalized_approval_from_type(_event, _legacy_event, _update), do: nil

  defp approval_kind(method) when method in ["item/fileChange/requestApproval", "applyPatchApproval"], do: :file
  defp approval_kind(method) when method in ["item/commandExecution/requestApproval", "execCommandApproval"], do: :command
  defp approval_kind("item/tool/requestUserInput"), do: :tool
  defp approval_kind("mcpServer/elicitation/request"), do: :mcp
  defp approval_kind(_method), do: :tool

  @spec normalize_error(term()) :: Error.t()
  def normalize_error(reason), do: normalize_error(reason, :provider)

  @spec normalize_error(term(), atom()) :: Error.t()
  def normalize_error(%Error{} = error, _context), do: error

  def normalize_error({:approval_required, raw}, _context) do
    Error.new(:approval_required, "agent approval is required",
      code: :approval_required,
      blocked?: true,
      raw: raw
    )
  end

  def normalize_error({:turn_input_required, raw}, _context) do
    Error.new(:input_required, "agent input is required",
      code: :input_required,
      blocked?: true,
      raw: raw
    )
  end

  def normalize_error(:turn_timeout, _context) do
    Error.new(:timeout, "agent turn timed out", code: :turn_timeout, retryable?: true, raw: :turn_timeout)
  end

  def normalize_error(:response_timeout, _context) do
    Error.new(:timeout, "agent response timed out",
      code: :response_timeout,
      retryable?: true,
      raw: :response_timeout
    )
  end

  def normalize_error({:port_exit, status} = raw, _context) do
    Error.new(:process_exit, "agent process exited with status #{status}",
      code: status,
      retryable?: true,
      raw: raw
    )
  end

  def normalize_error({:turn_cancelled, raw}, _context) do
    Error.new(:cancelled, "agent turn was cancelled", code: :turn_cancelled, retryable?: true, raw: raw)
  end

  def normalize_error({:turn_failed, raw}, _context) do
    Error.new(:provider, "agent turn failed", code: :turn_failed, retryable?: true, raw: raw)
  end

  def normalize_error(reason, _context)
      when is_tuple(reason) and tuple_size(reason) > 0 and
             elem(reason, 0) == :workspace_prepare_failed do
    Error.new(:startup, "agent workspace preparation failed",
      code: :workspace_prepare_failed,
      retryable?: true,
      raw: reason
    )
  end

  def normalize_error(reason, context) do
    Error.new(context, format_reason(reason), code: context, retryable?: context != :protocol, raw: reason)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
