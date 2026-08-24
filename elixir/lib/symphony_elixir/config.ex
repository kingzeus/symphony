defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.{AgentServer, Config.Schema, Tracker}
  alias SymphonyElixir.{Workflow, WorkflowStore}

  @default_prompt_template """
  You are working on an issue from the configured tracker.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type claude_code_runtime_settings :: %{
          command: String.t(),
          model: String.t() | nil,
          permission_mode: String.t(),
          allowed_tools: [String.t()],
          disallowed_tools: [String.t()],
          mcp_config: String.t() | map() | nil,
          include_partial_messages: boolean(),
          turn_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    WorkflowStore.settings()
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @doc false
  @spec local_workspace_root() :: Path.t()
  def local_workspace_root do
    workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
    Path.expand(settings!().workspace.root, workflow_dir)
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    WorkflowStore.force_reload()
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec agent_backend() :: :codex | :claude_code
  def agent_backend do
    case settings!().agent.backend do
      "claude_code" -> :claude_code
      _ -> :codex
    end
  end

  @spec agent_backend_module() :: module()
  def agent_backend_module, do: AgentServer.backend_module(agent_backend())

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms, do: agent_stall_timeout_ms(agent_backend())

  @spec agent_stall_timeout_ms(:codex | :claude_code) :: non_neg_integer()
  def agent_stall_timeout_ms(backend) when backend in [:codex, :claude_code] do
    settings = settings!()

    case backend do
      :claude_code -> settings.claude_code.stall_timeout_ms
      :codex -> settings.codex.stall_timeout_ms
    end
  end

  @spec claude_code_runtime_settings() :: claude_code_runtime_settings()
  def claude_code_runtime_settings do
    settings = settings!().claude_code

    %{
      command: settings.command,
      model: settings.model,
      permission_mode: settings.permission_mode,
      allowed_tools: settings.allowed_tools,
      disallowed_tools: settings.disallowed_tools,
      mcp_config: settings.mcp_config,
      include_partial_messages: settings.include_partial_messages,
      turn_timeout_ms: settings.turn_timeout_ms,
      stall_timeout_ms: settings.stall_timeout_ms
    }
  end

  @doc false
  @spec validate_settings(Schema.t()) :: :ok | {:error, term()}
  def validate_settings(settings) do
    if is_nil(settings.tracker.kind) do
      {:error, :missing_tracker_kind}
    else
      Tracker.validate_config(settings.tracker)
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
