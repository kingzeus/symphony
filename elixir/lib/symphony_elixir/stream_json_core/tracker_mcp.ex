defmodule SymphonyElixir.StreamJsonCore.TrackerMcp do
  @moduledoc """
  Provider-agnostic injection of the host-managed restricted Tracker MCP into a
  stream-json backend turn. Shared by Claude Code and Qoder (both consume the same
  `ClaudeTrackerMCP` bridge and issue-scoped tools). The dialect backend calls
  `prepare/5` before spawning and closes the returned capability token afterwards.
  """

  alias SymphonyElixir.{ClaudeTrackerMCP, Config, HttpServer, StreamJsonCore}

  @tracker_mcp_path "/api/v1/agent-mcp"

  @spec prepare(map(), map(), map(), String.t(), String.t()) ::
          {:ok, map(), String.t() | nil} | {:error, term()}
  def prepare(%{worker_host: worker_host}, _issue, settings, _session_id, _turn_id)
      when is_binary(worker_host) do
    {:ok, settings, nil}
  end

  def prepare(session, issue, settings, session_id, turn_id) do
    tool_specs = Map.get(session.tracker_binding, :scoped_tool_specs, [])

    if auto_tracker_mcp?(tool_specs, settings.mcp_config) do
      open_tracker_mcp(session, issue, settings, session_id, turn_id, tool_specs)
    else
      {:ok, settings, nil}
    end
  end

  @spec close(String.t() | nil) :: :ok
  def close(token), do: ClaudeTrackerMCP.close(token)

  defp auto_tracker_mcp?(tool_specs, mcp_config) do
    tool_specs != [] and mergeable_mcp_config?(mcp_config) and not is_nil(tracker_mcp_port())
  end

  defp mergeable_mcp_config?(config) when is_binary(config), do: not is_nil(StreamJsonCore.inline_mcp_payload(config))
  defp mergeable_mcp_config?(_config), do: true

  defp open_tracker_mcp(session, issue, settings, session_id, turn_id, tool_specs) do
    case ClaudeTrackerMCP.open(
           session.tracker_binding,
           issue,
           session_id,
           turn_id,
           ttl_ms: settings.turn_timeout_ms + 60_000,
           workspace: session.workspace
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
    config_map = StreamJsonCore.inline_mcp_payload(config) |> decode_inline_mcp_config()
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
end
