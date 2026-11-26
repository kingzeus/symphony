defmodule SymphonyElixir.ClaudeTrackerMCPTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import ExUnit.CaptureLog

  alias SymphonyElixir.ClaudeTrackerMCP

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeAdapter do
    def execute_scoped_agent_tool("fake_tool", arguments, opts) do
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      issue = Keyword.fetch!(opts, :issue)
      send(tracker_settings.recipient, {:fake_tool, arguments, issue, Keyword.get(opts, :workspace)})

      if Map.get(arguments, "ok", true) do
        %{"success" => true, "output" => Jason.encode!(%{"echo" => arguments})}
      else
        %{"success" => false, "output" => "failed"}
      end
    end
  end

  setup do
    issue = %Issue{id: "issue-mcp", identifier: "MCP-1", state: "In Progress"}

    binding = %{
      adapter: FakeAdapter,
      tracker_settings: %{recipient: self()},
      secret_environment_names: ["LINEAR_API_KEY"],
      scoped_tool_specs: [
        %{
          "name" => "fake_tool",
          "description" => "Fake tracker tool",
          "inputSchema" => %{"type" => "object", "additionalProperties" => true}
        }
      ]
    }

    %{binding: binding, issue: issue}
  end

  test "capability lifecycle rejects invalid inputs, expires, and revokes", context do
    name = Module.concat(__MODULE__, :Lifecycle)
    start_supervised!({ClaudeTrackerMCP, name: name})

    assert ClaudeTrackerMCP.server_name() == "symphony_tracker"

    assert {:error, :invalid_claude_tracker_mcp_ttl} =
             ClaudeTrackerMCP.open(context.binding, context.issue, "session", "turn", server: name, ttl_ms: 0)

    assert {:error, :claude_tracker_mcp_has_no_tools} =
             ClaudeTrackerMCP.open(
               %{context.binding | scoped_tool_specs: []},
               context.issue,
               "session",
               "turn",
               server: name
             )

    assert {:error, :claude_tracker_mcp_unavailable} =
             ClaudeTrackerMCP.open(
               context.binding,
               context.issue,
               "session",
               "turn",
               server: Module.concat(__MODULE__, :Missing)
             )

    assert {:ok, token} =
             ClaudeTrackerMCP.open(context.binding, context.issue, "session", "turn", server: name, ttl_ms: 10)

    assert {:ok, %{session_id: "session", turn_id: "turn"}} = ClaudeTrackerMCP.lookup(token, server: name)
    Process.sleep(15)
    assert {:error, :unauthorized} = ClaudeTrackerMCP.lookup(token, server: name)
    assert {:error, :unauthorized} = ClaudeTrackerMCP.lookup("missing", server: Module.concat(__MODULE__, :Missing))

    assert {:ok, token} =
             ClaudeTrackerMCP.open(context.binding, context.issue, "session", "turn", server: name)

    assert :ok = ClaudeTrackerMCP.close(token, server: name)
    assert {:error, :unauthorized} = ClaudeTrackerMCP.lookup(token, server: name)
    assert :ok = ClaudeTrackerMCP.close(nil, server: name)
    assert :ok = ClaudeTrackerMCP.close("missing", server: Module.concat(__MODULE__, :Missing))
  end

  test "JSON-RPC exposes tracker tools and executes them with issue context", context do
    assert {:ok, token} = ClaudeTrackerMCP.open(context.binding, context.issue, "session-1", "turn-1")
    assert {:ok, capability} = ClaudeTrackerMCP.lookup(token)

    assert {:ok,
            %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{"tools" => %{"listChanged" => false}}
              }
            }} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert {:ok, %{"result" => %{"protocolVersion" => "2025-03-26"}}} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "initialize",
               "params" => %{}
             })

    assert {:ok, %{"id" => 3, "result" => %{}}} =
             ClaudeTrackerMCP.handle_request(capability, %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"})

    assert {:ok, %{"result" => %{"tools" => tools}}} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/list"
             })

    assert Enum.map(tools, & &1["name"]) == ["fake_tool"]

    assert {:ok,
            %{
              "id" => 5,
              "result" => %{
                "isError" => false,
                "content" => [%{"type" => "text", "text" => output}]
              }
            }} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 5,
               "method" => "tools/call",
               "params" => %{"name" => "fake_tool", "arguments" => %{"value" => 7}}
             })

    assert Jason.decode!(output) == %{"echo" => %{"value" => 7}}
    expected_issue = context.issue
    assert_received {:fake_tool, %{"value" => 7}, ^expected_issue, nil}

    assert {:ok, %{"result" => %{"isError" => true}}} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 6,
               "method" => "tools/call",
               "params" => %{"name" => "fake_tool", "arguments" => %{"ok" => false}}
             })

    assert :accepted =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             ClaudeTrackerMCP.handle_request(capability, %{"jsonrpc" => "2.0", "id" => 8, "method" => "unknown"})
  end

  test "capability workspace is forwarded to scoped tool execution", context do
    assert {:ok, token} =
             ClaudeTrackerMCP.open(context.binding, context.issue, "session-ws", "turn-ws", workspace: "/tmp/issue-workspace")

    assert {:ok, capability} = ClaudeTrackerMCP.lookup(token)
    assert capability.workspace == "/tmp/issue-workspace"

    assert {:ok, %{"result" => %{"isError" => false}}} =
             ClaudeTrackerMCP.handle_request(capability, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "tools/call",
               "params" => %{"name" => "fake_tool", "arguments" => %{}}
             })

    expected_issue = context.issue
    assert_received {:fake_tool, %{}, ^expected_issue, "/tmp/issue-workspace"}
  end

  test "JSON-RPC rejects malformed tool calls", context do
    assert {:ok, token} = ClaudeTrackerMCP.open(context.binding, context.issue, "session-2", "turn-2")
    assert {:ok, capability} = ClaudeTrackerMCP.lookup(token)

    for request <- [
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{}},
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{"name" => "fake_tool", "arguments" => []}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{"name" => "missing", "arguments" => %{}}
          }
        ] do
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               ClaudeTrackerMCP.handle_request(capability, request)
    end
  end

  test "HTTP endpoint requires bearer auth and serves MCP requests", context do
    start_test_endpoint()
    assert {:ok, token} = ClaudeTrackerMCP.open(context.binding, context.issue, "session-http", "turn-http")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list"
    }

    assert json_response(post(build_conn(), "/api/v1/agent-mcp", request), 401) == %{
             "error" => %{"code" => "unauthorized", "message" => "Unauthorized"}
           }

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/agent-mcp", request)

    assert %{"result" => %{"tools" => [%{"name" => "fake_tool"}]}} =
             json_response(conn, 200)

    notification_conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/agent-mcp", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert response(notification_conn, 202) == ""

    assert json_response(get(build_conn(), "/api/v1/agent-mcp"), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }
  end

  test "MCP route and Phoenix filters never log raw tool input", context do
    start_test_endpoint()
    assert {:ok, token} = ClaudeTrackerMCP.open(context.binding, context.issue, "session-log", "turn-log")

    secret = "RAW_TOOL_INPUT_MUST_NOT_APPEAR"

    log =
      capture_log([level: :debug], fn ->
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
          |> post("/api/v1/agent-mcp", %{
            "jsonrpc" => "2.0",
            "id" => 9,
            "method" => "tools/call",
            "params" => %{
              "name" => "fake_tool",
              "arguments" => %{"secret" => secret}
            }
          })

        assert %{"result" => %{"isError" => false}} = json_response(conn, 200)
      end)

    refute log =~ secret
    refute log =~ "Parameters:"

    assert Phoenix.Logger.filter_values(%{
             "arguments" => %{"query" => secret},
             "safe" => "visible"
           }) == %{"arguments" => "[FILTERED]", "safe" => "visible"}
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
