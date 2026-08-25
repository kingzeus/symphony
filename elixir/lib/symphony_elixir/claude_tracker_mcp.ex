defmodule SymphonyElixir.ClaudeTrackerMCP do
  @moduledoc """
  Hosts short-lived tracker capabilities for Claude Code MCP turns.

  Claude receives only an opaque bearer token. Tracker credentials and adapter
  settings remain in the Symphony BEAM, and every token is bound to one issue,
  session, and turn before it can execute the selected adapter's native tools.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  @default_ttl_ms 3_660_000
  @protocol_version "2025-03-26"
  @server_name "symphony_tracker"

  @type capability :: %{
          binding: map(),
          issue: Issue.t() | map(),
          session_id: String.t(),
          turn_id: String.t(),
          expires_at_ms: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @spec open(map(), Issue.t() | map(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def open(binding, issue, session_id, turn_id, opts \\ [])
      when is_map(binding) and is_map(issue) and is_binary(session_id) and is_binary(turn_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    cond do
      not is_integer(ttl_ms) or ttl_ms <= 0 ->
        {:error, :invalid_claude_tracker_mcp_ttl}

      not is_list(Map.get(binding, :scoped_tool_specs)) or Map.get(binding, :scoped_tool_specs) == [] ->
        {:error, :claude_tracker_mcp_has_no_tools}

      true ->
        GenServer.call(server, {:open, binding, issue, session_id, turn_id, ttl_ms})
    end
  catch
    :exit, _reason -> {:error, :claude_tracker_mcp_unavailable}
  end

  @spec close(String.t() | nil, keyword()) :: :ok
  def close(token, opts \\ []) do
    if is_binary(token) do
      server = Keyword.get(opts, :server, __MODULE__)
      GenServer.cast(server, {:close, token})
    end

    :ok
  end

  @spec lookup(String.t(), keyword()) :: {:ok, capability()} | {:error, :unauthorized}
  def lookup(token, opts \\ []) when is_binary(token) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:lookup, token})
  catch
    :exit, _reason -> {:error, :unauthorized}
  end

  @spec handle_request(capability(), map()) :: {:ok, map()} | :accepted
  def handle_request(capability, request) when is_map(capability) and is_map(request) do
    id = Map.get(request, "id")
    method = Map.get(request, "method")

    case method do
      "initialize" ->
        {:ok, success_response(id, initialize_result(request))}

      "ping" ->
        {:ok, success_response(id, %{})}

      "tools/list" ->
        {:ok, success_response(id, %{"tools" => tool_specs(capability)})}

      "tools/call" ->
        handle_tool_call(capability, request, id)

      method when is_binary(method) and is_nil(id) ->
        :accepted

      _other ->
        {:ok, error_response(id, -32_601, "Method not found")}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{capabilities: %{}}}

  @impl true
  def handle_call({:open, binding, issue, session_id, turn_id, ttl_ms}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now_ms = System.monotonic_time(:millisecond)

    capability = %{
      binding: binding,
      issue: issue,
      session_id: session_id,
      turn_id: turn_id,
      expires_at_ms: now_ms + ttl_ms
    }

    capabilities = state.capabilities |> discard_expired(now_ms) |> Map.put(token, capability)
    {:reply, {:ok, token}, %{state | capabilities: capabilities}}
  end

  def handle_call({:lookup, token}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    capabilities = discard_expired(state.capabilities, now_ms)

    case Map.fetch(capabilities, token) do
      {:ok, capability} -> {:reply, {:ok, capability}, %{state | capabilities: capabilities}}
      :error -> {:reply, {:error, :unauthorized}, %{state | capabilities: capabilities}}
    end
  end

  @impl true
  def handle_cast({:close, token}, state) do
    {:noreply, %{state | capabilities: Map.delete(state.capabilities, token)}}
  end

  defp initialize_result(request) do
    requested_version = get_in(request, ["params", "protocolVersion"])

    %{
      "protocolVersion" => if(is_binary(requested_version), do: requested_version, else: @protocol_version),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "Symphony Tracker MCP", "version" => "1"}
    }
  end

  defp handle_tool_call(capability, request, id) do
    params = Map.get(request, "params")
    name = if is_map(params), do: Map.get(params, "name")
    arguments = if is_map(params), do: Map.get(params, "arguments", %{})

    cond do
      not is_binary(name) or name == "" ->
        {:ok, error_response(id, -32_602, "tools/call requires a tool name")}

      not is_map(arguments) ->
        {:ok, error_response(id, -32_602, "tools/call arguments must be an object")}

      name not in tool_names(capability) ->
        {:ok, error_response(id, -32_602, "Unknown tool")}

      true ->
        result =
          Tracker.execute_bound_scoped_agent_tool(
            capability.binding,
            name,
            arguments,
            issue: capability.issue
          )

        log_tool_result(capability, name, result)
        {:ok, success_response(id, mcp_tool_result(result))}
    end
  end

  defp tool_specs(%{binding: %{scoped_tool_specs: specs}}) do
    Enum.map(specs, fn spec ->
      %{
        "name" => Map.get(spec, "name") || Map.get(spec, :name),
        "description" => Map.get(spec, "description") || Map.get(spec, :description) || "",
        "inputSchema" => Map.get(spec, "inputSchema") || Map.get(spec, :inputSchema) || %{"type" => "object"}
      }
    end)
  end

  defp tool_names(capability), do: Enum.map(tool_specs(capability), &Map.get(&1, "name"))

  defp mcp_tool_result(result) when is_map(result) do
    success = Map.get(result, "success") == true or Map.get(result, :success) == true
    output = Map.get(result, "output") || Map.get(result, :output) || Jason.encode!(result)

    %{
      "content" => [%{"type" => "text", "text" => to_string(output)}],
      "isError" => not success
    }
  end

  defp log_tool_result(capability, tool, result) do
    issue = capability.issue
    issue_id = Map.get(issue, :id) || Map.get(issue, "id") || "n/a"
    issue_identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "n/a"

    success = Map.get(result, "success") == true or Map.get(result, :success) == true

    Logger.info(
      "Claude tracker MCP tool call completed issue_id=#{issue_id} " <>
        "issue_identifier=#{issue_identifier} session_id=#{capability.session_id} " <>
        "turn_id=#{capability.turn_id} tool=#{tool} success=#{success}"
    )
  end

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp discard_expired(capabilities, now_ms) do
    Map.reject(capabilities, fn {_token, capability} -> capability.expires_at_ms <= now_ms end)
  end
end
