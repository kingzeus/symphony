defmodule SymphonyElixir.ClaudeCodeBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentServer.{Error, Event, Usage, WorkspaceGuard}
  alias SymphonyElixir.ClaudeCodeBackend
  alias SymphonyElixir.PathSafety

  @max_stream_frame_bytes 10_485_760
  @provider_session_1 "11111111-1111-4111-8111-111111111111"
  @provider_session_2 "22222222-2222-4222-8222-222222222222"

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-backend-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "CLAUDE-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "claude-issue-1",
      identifier: "CLAUDE-1",
      title: "Claude backend",
      description: "test",
      state: "In Progress",
      url: "https://example.test/CLAUDE-1",
      labels: [],
      dispatchable: true
    }

    %{test_root: test_root, workspace_root: workspace_root, workspace: workspace, issue: issue}
  end

  test "start_session 使用合法 UUID，并拒绝 root/outside/symlink escape", context do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code"
    )

    assert {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert session.backend == :claude_code
    assert session.worker_host == nil
    assert session.turn_count == 0
    assert String.match?(session.session_id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :workspace_root, _}}} =
             ClaudeCodeBackend.start_session(context.workspace_root)

    outside = Path.join(context.test_root, "outside")
    File.mkdir_p!(outside)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :outside_workspace_root, _, _}}} =
             ClaudeCodeBackend.start_session(outside)

    escape = Path.join(context.workspace_root, "escape")
    File.ln_s!(outside, escape)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :symlink_escape, _, _}}} =
             ClaudeCodeBackend.start_session(escape)

    locked = Path.join(context.workspace_root, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o000)
    unreadable = Path.join(locked, "child")

    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :path_unreadable, ^unreadable, _}}} =
             ClaudeCodeBackend.start_session(unreadable)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :empty_remote_workspace, "worker-a"}}} =
             ClaudeCodeBackend.start_session(" ", worker_host: "worker-a")

    assert {:error,
            %Error{
              kind: :startup,
              raw: {:invalid_workspace_cwd, :invalid_remote_workspace, "worker-a", "bad\nworkspace"}
            }} = ClaudeCodeBackend.start_session("bad\nworkspace", worker_host: "worker-a")
  end

  test "本地 CLI 使用安全 stdin framing，保留 command prefix/argv/大 prompt，并返回真实 session", context do
    trace = Path.join(context.test_root, "claude.trace")
    fake = install_fake_claude!(context.test_root, success_script(trace))
    previous_trace = System.get_env("SYMP_CLAUDE_TRACE")
    previous_secret = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("SYMP_CLAUDE_TRACE", previous_trace)
      restore_env("LINEAR_API_KEY", previous_secret)
    end)

    System.put_env("SYMP_CLAUDE_TRACE", trace)
    System.put_env("LINEAR_API_KEY", "must-not-leak")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: "env CLAUDE_PREFIX=present #{fake}",
      claude_code_model: "sonnet",
      claude_code_permission_mode: "acceptEdits",
      claude_code_allowed_tools: ["Read", "Edit"],
      claude_code_disallowed_tools: ["Bash"],
      claude_code_mcp_config: %{"mcpServers" => %{}},
      claude_code_include_partial_messages: true
    )

    prompt = String.duplicate("line '$HOME' ; \\ newline\n", 8_000)
    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:ok, result} =
             ClaudeCodeBackend.run_turn(session, prompt, context.issue, on_message: &send(test_pid, {:claude_event, &1}))

    assert result.session.session_id == @provider_session_1
    assert result.session.resume_session_id == @provider_session_1
    assert result.session.turn_count == 1

    assert_received {:claude_event, %Event{backend: :claude_code, type: :session_started, process_id: process_id}}

    assert is_binary(process_id) and process_id != ""
    assert_received {:claude_event, %Event{type: :notification, payload: %{"type" => "assistant"}}}

    assert_received {:claude_event,
                     %Event{
                       type: :turn_completed,
                       session_id: @provider_session_1,
                       usage: %Usage{
                         mode: :delta,
                         scope: :turn,
                         input_tokens: 12,
                         output_tokens: 5,
                         total_tokens: nil,
                         cache_read_input_tokens: 3,
                         cache_creation_input_tokens: 2
                       }
                     }}

    trace_text = File.read!(trace)
    assert trace_text =~ "PREFIX:present"
    assert trace_text =~ "SECRET:unset"
    assert trace_text =~ "--print"
    assert trace_text =~ "--input-format|text"
    assert trace_text =~ "--output-format|stream-json"
    assert trace_text =~ "--include-partial-messages"
    assert trace_text =~ "--session-id|#{session.session_id}"
    assert trace_text =~ "--model|sonnet"
    assert trace_text =~ "--permission-mode|acceptEdits"
    assert trace_text =~ "--allowedTools|Read"
    assert trace_text =~ "--allowedTools|Edit"
    assert trace_text =~ "--disallowedTools|Bash"
    assert trace_text =~ "--setting-sources|user"
    assert trace_text =~ "--strict-mcp-config"
    assert trace_text =~ "--mcp-config|"
    refute trace_text =~ ~s|{"mcpServers":{}}|
    assert File.read!(trace <> ".prompt") == prompt
    assert File.read!(trace <> ".mode") |> String.trim() == "600"
    prompt_path = File.read!(trace <> ".prompt_path") |> String.trim()
    stderr_path = File.read!(trace <> ".stderr_path") |> String.trim()
    assert stderr_path == "/dev/null"
    refute File.exists?(prompt_path)
    assert File.exists?(stderr_path)
  end

  test "Port 启动后子进程瞬时退出仍返回 typed error 且不泄漏临时目录", context do
    fake = install_fake_claude!(context.test_root, "#!/bin/sh\nexit 0\n", "instant-exit")
    temp_glob = Path.join(System.tmp_dir!(), "symphony-claude-*")
    before = temp_glob |> Path.wildcard() |> MapSet.new()

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    assert {:error, %Error{kind: kind, code: code}} =
             ClaudeCodeBackend.run_turn(session, "instant", context.issue)

    assert kind in [:process_exit, :protocol]
    assert code in [:port_closed, :missing_result]
    assert MapSet.difference(temp_glob |> Path.wildcard() |> MapSet.new(), before) == MapSet.new()
  end

  test "session_started 回调期间 Port 关闭会映射 typed process_exit 并清理", context do
    fake = install_fake_claude!(context.test_root, "#!/bin/sh\ncat >/dev/null\nsleep 10\n", "close-before-input")
    kill = System.find_executable("kill")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    on_message = fn
      %Event{type: :session_started, process_id: process_id} when is_binary(process_id) ->
        _ = System.cmd(kill, ["-KILL", process_id], stderr_to_stdout: true)
        Process.sleep(50)

      _event ->
        :ok
    end

    assert {:error, %Error{kind: :process_exit, code: :port_closed, retryable?: true}} =
             ClaudeCodeBackend.run_turn(session, "closed", context.issue, on_message: on_message)
  end

  test "默认隔离 project settings，strict MCP map 通过 0600 临时文件且 secret 不进入 argv", context do
    trace = Path.join(context.test_root, "secure-mcp.trace")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf 'ARGV:' > #{shell_literal(trace)}
        previous=''
        mcp_path=''
        for arg in "$@"; do
          printf '%s|' "$arg" >> #{shell_literal(trace)}
          [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
          previous="$arg"
        done
        printf '\n' >> #{shell_literal(trace)}
        printf '%s\n' "$mcp_path" > #{shell_literal(trace <> ".mcp_path")}
        cat "$mcp_path" > #{shell_literal(trace <> ".mcp")}
        stat -f '%Lp' "$mcp_path" > #{shell_literal(trace <> ".mode")} 2>/dev/null || stat -c '%a' "$mcp_path" > #{shell_literal(trace <> ".mode")}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "secure-mcp"
      )

    project_settings = Path.join([context.workspace, ".claude", "settings.json"])
    File.mkdir_p!(Path.dirname(project_settings))
    File.write!(project_settings, ~s|{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"false"}]}]}}|)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_mcp_config: %{
        "mcpServers" => %{
          "private" => %{"command" => "server", "env" => %{"TOKEN" => "mcp-super-secret"}}
        }
      }
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "secure", context.issue)

    argv = File.read!(trace)
    assert argv =~ "--setting-sources|user"
    assert argv =~ "--strict-mcp-config"
    refute argv =~ "mcp-super-secret"
    refute argv =~ ~s|{"mcpServers"|
    assert File.read!(trace <> ".mcp") =~ "mcp-super-secret"
    assert File.read!(trace <> ".mode") |> String.trim() == "600"
    mcp_path = File.read!(trace <> ".mcp_path") |> String.trim()
    refute File.exists?(mcp_path)
  end

  test "inline JSON 字符串 MCP 配置使用 0600 临时文件且 secret 不进入 argv", context do
    trace = Path.join(context.test_root, "inline-mcp.trace")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        previous=''
        mcp_path=''
        printf 'ARGV:' > #{shell_literal(trace)}
        for arg in "$@"; do
          printf '%s|' "$arg" >> #{shell_literal(trace)}
          [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
          previous="$arg"
        done
        cat "$mcp_path" > #{shell_literal(trace <> ".mcp")}
        stat -f '%Lp' "$mcp_path" > #{shell_literal(trace <> ".mode")} 2>/dev/null || stat -c '%a' "$mcp_path" > #{shell_literal(trace <> ".mode")}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "inline-mcp"
      )

    inline_json = ~s|{"mcpServers":{"private":{"command":"server","env":{"TOKEN":"inline-secret"}}}}|

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_mcp_config: inline_json
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "inline mcp", context.issue)
    refute File.read!(trace) =~ "inline-secret"
    assert File.read!(trace <> ".mcp") =~ "inline-secret"
    assert String.trim(File.read!(trace <> ".mode")) in ["600", "0600"]
  end

  test "本地 Claude turn 自动注入宿主机 Tracker MCP、精确放行工具并撤销 capability", context do
    trace = Path.join(context.test_root, "tracker-mcp.trace")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf 'ARGV:' > #{shell_literal(trace)}
        previous=''
        mcp_path=''
        for arg in "$@"; do
          printf '%s|' "$arg" >> #{shell_literal(trace)}
          [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
          previous="$arg"
        done
        printf '\n' >> #{shell_literal(trace)}
        cat "$mcp_path" > #{shell_literal(trace <> ".mcp")}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "tracker-mcp"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_allowed_tools: ["Bash(pwd)"],
      claude_code_mcp_config: %{
        "mcpServers" => %{"private" => %{"command" => "private-server"}}
      },
      server_port: 45_678,
      server_host: "0.0.0.0"
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "tracker", context.issue)

    argv = File.read!(trace)
    assert argv =~ "--allowedTools|Bash(pwd)"
    assert argv =~ "--allowedTools|mcp__symphony_tracker__tracker_issue_get"
    assert argv =~ "--allowedTools|mcp__symphony_tracker__tracker_workpad_upsert"
    assert argv =~ "--allowedTools|mcp__symphony_tracker__tracker_issue_transition"
    refute argv =~ "mcp__symphony_tracker__linear_graphql"

    config = (trace <> ".mcp") |> File.read!() |> Jason.decode!()
    assert get_in(config, ["mcpServers", "private", "command"]) == "private-server"

    tracker_server = get_in(config, ["mcpServers", "symphony_tracker"])
    assert tracker_server["type"] == "http"
    assert tracker_server["url"] == "http://127.0.0.1:45678/api/v1/agent-mcp"
    assert "Bearer " <> token = get_in(tracker_server, ["headers", "Authorization"])
    assert {:error, :unauthorized} = SymphonyElixir.ClaudeTrackerMCP.lookup(token)
  end

  test "Tracker MCP 支持空配置与显式本地主机", context do
    trace = Path.join(context.test_root, "tracker-mcp-nil.trace")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        previous=''
        mcp_path=''
        for arg in "$@"; do
          [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
          previous="$arg"
        done
        cat "$mcp_path" > #{shell_literal(trace)}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "tracker-mcp-nil"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      server_port: 45_679,
      server_host: "localhost"
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "tracker nil", context.issue)

    config = trace |> File.read!() |> Jason.decode!()

    assert get_in(config, ["mcpServers", "symphony_tracker", "url"]) ==
             "http://localhost:45679/api/v1/agent-mcp"
  end

  test "无效自动 Tracker MCP 配置返回 typed startup error 并撤销 capability", context do
    fake = install_fake_claude!(context.test_root, "#!/bin/sh\nexit 99\n", "invalid-tracker-mcp")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_mcp_config: %{"mcpServers" => "invalid"},
      server_port: 45_680
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :startup, raw: :invalid_claude_mcp_servers}} =
             ClaudeCodeBackend.run_turn(session, "invalid tracker", context.issue, on_message: &send(test_pid, {:event, &1}))

    assert_received {:event,
                     %Event{
                       type: :startup_failed,
                       error: %Error{raw: :invalid_claude_mcp_servers}
                     }}
  end

  test "Tracker MCP registry 不可用时返回 typed startup error", context do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.ClaudeTrackerMCP)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.ClaudeTrackerMCP)) do
        _ = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.ClaudeTrackerMCP)
      end
    end)

    fake = install_fake_claude!(context.test_root, "#!/bin/sh\nexit 99\n", "missing-tracker-mcp")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      server_port: 45_681
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    assert {:error, %Error{kind: :startup, raw: :claude_tracker_mcp_unavailable}} =
             ClaudeCodeBackend.run_turn(session, "missing tracker", context.issue)

    assert {:ok, _pid} =
             Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.ClaudeTrackerMCP)
  end

  test "第二轮使用 provider 返回的真实 session_id 通过 --resume 延续", context do
    trace = Path.join(context.test_root, "resume.trace")
    fake = install_fake_claude!(context.test_root, resume_script(trace))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, first} = ClaudeCodeBackend.run_turn(session, "first", context.issue)
    assert first.session.resume_session_id == @provider_session_1
    assert {:ok, second} = ClaudeCodeBackend.run_turn(first.session, "second", context.issue)
    assert second.session.resume_session_id == @provider_session_2

    [first_argv, second_argv] = File.read!(trace) |> String.split("\n", trim: true)
    assert first_argv =~ "--session-id|#{session.session_id}"
    refute first_argv =~ "--resume"
    assert second_argv =~ "--resume|#{@provider_session_1}"
    refute second_argv =~ "--session-id"
  end

  test "session 冻结 tracker binding，reload 后仍清除所有 provider secret env", context do
    trace = Path.join(context.test_root, "provider-secrets.trace")
    secret_names = ["LINEAR_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_PAT", "JIRA_API_TOKEN", "ASANA_PAT"]
    previous = Map.new(secret_names, &{&1, System.get_env(&1)})

    Enum.each(secret_names, &System.put_env(&1, "must-not-leak-#{&1}"))
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf 'LINEAR_API_KEY:%s\n' "${LINEAR_API_KEY:-unset}" > #{shell_literal(trace)}
        printf 'GITHUB_TOKEN:%s\n' "${GITHUB_TOKEN:-unset}" >> #{shell_literal(trace)}
        printf 'GH_TOKEN:%s\n' "${GH_TOKEN:-unset}" >> #{shell_literal(trace)}
        printf 'GITLAB_PAT:%s\n' "${GITLAB_PAT:-unset}" >> #{shell_literal(trace)}
        printf 'JIRA_API_TOKEN:%s\n' "${JIRA_API_TOKEN:-unset}" >> #{shell_literal(trace)}
        printf 'ASANA_PAT:%s\n' "${ASANA_PAT:-unset}" >> #{shell_literal(trace)}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "provider-secrets"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: "false"
    )

    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "secrets", context.issue)

    trace_text = File.read!(trace)
    Enum.each(secret_names, &assert(trace_text =~ "#{&1}:unset"))
  end

  test "noeol、partial heartbeat 和 tool activity 会被解析且刷新静默 timeout", context do
    fake =
      install_fake_claude!(context.test_root, """
      #!/bin/sh
      cat >/dev/null
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta"}}'
      sleep 0.40
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta"}}'
      sleep 0.40
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
      sleep 0.40
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta"}}'
      sleep 0.40
      printf '%s' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 1_500
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:ok, result} =
             ClaudeCodeBackend.run_turn(session, "heartbeat", context.issue, on_message: &send(test_pid, {:event, &1}))

    assert result.session.session_id == @provider_session_1
    assert_received {:event, %Event{type: :progress}}
    assert_received {:event, %Event{type: :tool_activity}}
    assert_received {:event, %Event{type: :turn_completed}}
  end

  test "stderr 不进入 stream-json parser", context do
    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}' >&2
        """,
        "stderr"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    assert {:error, %Error{kind: :protocol, code: :missing_result}} =
             ClaudeCodeBackend.run_turn(session, "stderr", context.issue)
  end

  test "success、provider failure、timeout 和 process exit 都清理 prompt/MCP/stderr 临时文件", context do
    cases = [
      {:success, ~s|printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'|},
      {:failure, ~s|printf '%s\n' '{"type":"result","is_error":true,"session_id":"#{@provider_session_1}","error":"bad request","usage":{"input_tokens":1,"output_tokens":1}}'|},
      {:timeout, "sleep 5"},
      {:process_exit, "exit 64"}
    ]

    Enum.each(cases, fn {name, outcome} ->
      trace = Path.join(context.test_root, "cleanup-#{name}")

      fake =
        install_fake_claude!(
          context.test_root,
          """
          #!/bin/sh
          previous=''
          mcp_path=''
          for arg in "$@"; do
            [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
            previous="$arg"
          done
          printf '%s\n%s\n%s\n' "${SYMPHONY_CLAUDE_PROMPT_FILE:-}" "$mcp_path" "${SYMPHONY_CLAUDE_STDERR_FILE:-}" > #{shell_literal(trace <> ".paths")}
          cat >/dev/null
          #{outcome}
          """,
          "cleanup-#{name}"
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake,
        claude_code_mcp_config: %{"mcpServers" => %{}},
        claude_code_turn_timeout_ms: if(name == :timeout, do: 3_000, else: 10_000)
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

      case name do
        :success -> assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "cleanup", context.issue)
        :failure -> assert {:error, %Error{kind: :provider}} = ClaudeCodeBackend.run_turn(session, "cleanup", context.issue)
        :timeout -> assert {:error, %Error{kind: :timeout}} = ClaudeCodeBackend.run_turn(session, "cleanup", context.issue)
        :process_exit -> assert {:error, %Error{kind: :process_exit}} = ClaudeCodeBackend.run_turn(session, "cleanup", context.issue)
      end

      assert_temp_paths_removed!(trace <> ".paths", name)
    end)
  end

  test "外部取消返回 typed cancelled，终止 OS 子孙进程并执行临时资源 cleanup", context do
    trace = Path.join(context.test_root, "cancel-tree")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf '%s\n%s\n%s\n' "${SYMPHONY_CLAUDE_PROMPT_FILE:-}" "unused" "${SYMPHONY_CLAUDE_STDERR_FILE:-}" > #{shell_literal(trace <> ".paths")}
        sh -c 'sleep 30 & echo $! > #{shell_literal(trace <> ".grandchild")}; wait' &
        echo $! > #{shell_literal(trace <> ".child")}
        wait
        """,
        "cancel-tree"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 5_000
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    task = Task.async(fn -> ClaudeCodeBackend.run_turn(session, "cancel", context.issue) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)

    assert wait_until(fn -> File.exists?(trace <> ".child") and File.exists?(trace <> ".grandchild") end)
    child_pid = (trace <> ".child") |> File.read!() |> String.trim() |> String.to_integer()
    grandchild_pid = (trace <> ".grandchild") |> File.read!() |> String.trim() |> String.to_integer()

    send(task.pid, {:agent_cancel, :orchestrator_stop})

    assert {:ok, {:error, %Error{kind: :cancelled, code: :orchestrator_stop}}} = Task.yield(task, 2_000)
    assert wait_until(fn -> not os_process_alive?(child_pid) and not os_process_alive?(grandchild_pid) end)
    assert_temp_paths_removed!(trace <> ".paths", :cancel_tree)
  end

  test "terminal provider error 锁定后静默 timeout 不覆盖根因", context do
    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf '%s\n' '{"type":"error","error":{"code":"fatal","message":"root cause"}}'
        sleep 5
        """,
        "terminal-timeout"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 2_000
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    assert {:error, %Error{kind: :provider, code: "fatal", retryable?: false}} =
             ClaudeCodeBackend.run_turn(session, "root cause", context.issue)
  end

  test "plain/未知 JSON flood 不刷新静默 timeout", context do
    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        i=0
        while [ "$i" -lt 50 ]; do
        printf '%s\n' 'diagnostic noise'
        printf '%s\n' '{}'
        printf '%s\n' '{"type":"future_unknown","message":"noise"}'
          sleep 0.04
          i=$((i + 1))
        done
        : > #{shell_literal(Path.join(context.test_root, "noise-flood.completed"))}
        """,
        "noise-flood"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 120
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :timeout}} = ClaudeCodeBackend.run_turn(session, "noise", context.issue)
    assert System.monotonic_time(:millisecond) - started < 1_500
    refute File.exists?(Path.join(context.test_root, "noise-flood.completed"))
  end

  test "超限 stream frame fail closed", context do
    Enum.each([10_485_761], fn frame_bytes ->
      fake =
        install_fake_claude!(
          context.test_root,
          """
          #!/bin/sh
          cat >/dev/null
          printf '%s' '{"type":"assistant","message":{"content":"'
          head -c #{frame_bytes} /dev/zero | tr '\\000' a
          printf '%s\n' '"}}'
          printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
          """,
          "oversize-#{frame_bytes}"
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

      assert {:error, %Error{kind: :protocol, code: :frame_too_large, retryable?: false}} =
               ClaudeCodeBackend.run_turn(session, "oversize", context.issue)
    end)
  end

  test "恰好 10 MB stream frame 可解析，超过 10 MB 才 fail closed", context do
    prefix = ~s|{"type":"assistant","message":{"content":"|
    suffix = ~s|"}}|
    padding_bytes = 10_485_760 - byte_size(prefix) - byte_size(suffix)

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s' #{shell_literal(prefix)}
        head -c #{padding_bytes} /dev/zero | tr '\\000' a
        printf '%s\n' #{shell_literal(suffix)}
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "exact-frame-limit"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 20_000
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, result} = ClaudeCodeBackend.run_turn(session, "frame limit", context.issue)
    assert result.session.session_id == @provider_session_1
  end

  test "permission denial 统一为 approval required 和 blocked error", context do
    fake =
      install_fake_claude!(context.test_root, """
      #!/bin/sh
      cat >/dev/null
      printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"#{@provider_session_1}","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm x"}}],"usage":{"input_tokens":2,"output_tokens":1}}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :approval_required, blocked?: true, retryable?: false}} =
             ClaudeCodeBackend.run_turn(session, "denied", context.issue, on_message: &send(test_pid, {:event, &1}))

    assert_received {:event,
                     %Event{
                       type: :approval_required,
                       approval: %{kind: :tool, status: :required},
                       error: %Error{blocked?: true}
                     }}
  end

  test "provider error、malformed JSON、非零退出和静默 timeout 都映射 typed error", context do
    cases = [
      {"provider", "printf '%s\\n' '{\"type\":\"error\",\"error\":{\"type\":\"rate_limit\",\"message\":\"slow down\"}}'", :provider, true},
      {"provider-429", "printf '%s\\n' '{\"type\":\"error\",\"error\":{\"code\":429,\"message\":\"too many requests\"}}'", :provider, true},
      {"provider-corporate", "printf '%s\\n' '{\"type\":\"error\",\"error\":{\"type\":\"corporate_policy_denied\",\"message\":\"denied\"}}'", :provider, false},
      {"malformed", "printf '%s\\n' '{\"type\":\"result\"'", :protocol, false},
      {"malformed-array", "printf '%s\\n' '[{\"type\":\"result\"'", :protocol, false},
      {"exit", "exit 23", :process_exit, true},
      {"timeout", "sleep 1", :timeout, true}
    ]

    Enum.each(cases, fn {name, body, kind, retryable?} ->
      fake = install_fake_claude!(context.test_root, "#!/bin/sh\ncat >/dev/null\n#{body}\n", name)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake,
        claude_code_turn_timeout_ms: if(name == "timeout", do: 50, else: 10_000)
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

      assert {:error, %Error{kind: ^kind, retryable?: ^retryable?}} =
               ClaudeCodeBackend.run_turn(session, name, context.issue)
    end)
  end

  test "SSH worker 使用同一 framing/config，远端 process exit 不会回退本地", context do
    previous_path = System.get_env("PATH")
    previous_secret = System.get_env("LINEAR_API_KEY")
    trace = Path.join(context.test_root, "ssh.trace")

    fake_claude =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        previous=''
        mcp_path=''
        printf 'ARGV:' > #{shell_literal(trace <> ".claude")}
        for arg in "$@"; do
          printf '%s|' "$arg" >> #{shell_literal(trace <> ".claude")}
          [ "$previous" = '--mcp-config' ] && mcp_path="$arg"
          previous="$arg"
        done
        printf '\nSECRET:%s\n' "${LINEAR_API_KEY:-unset}" >> #{shell_literal(trace <> ".claude")}
        cat "$mcp_path" > #{shell_literal(trace <> ".mcp")}
        cat > #{shell_literal(trace <> ".prompt")}
        printf '%s\n%s\n%s\n' "${SYMPHONY_CLAUDE_PROMPT_FILE:-}" "$mcp_path" "${SYMPHONY_CLAUDE_STDERR_FILE:-}" > #{shell_literal(trace <> ".paths")}
        exit 31
        """,
        "remote"
      )

    fake_bin = Path.join(context.test_root, "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\n' "$*" >> #{shell_literal(trace)}
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.put_env("LINEAR_API_KEY", "ssh-tracker-secret")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("LINEAR_API_KEY", previous_secret)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/",
      agent_backend: "claude_code",
      claude_code_command: fake_claude,
      claude_code_mcp_config: %{
        "mcpServers" => %{
          "private" => %{"command" => "server", "env" => %{"TOKEN" => "ssh-mcp-secret"}}
        }
      }
    )

    assert {:ok, session} = ClaudeCodeBackend.start_session(context.workspace, worker_host: "worker-a:2222")

    assert {:error, %Error{kind: :process_exit, code: 31}} =
             ClaudeCodeBackend.run_turn(session, "remote prompt", context.issue)

    trace_text = File.read!(trace)
    assert trace_text =~ "-p 2222 worker-a"
    assert trace_text =~ "dd bs=1 count=13"
    assert trace_text =~ fake_claude
    assert trace_text =~ "kill_tree()"
    assert trace_text =~ "command -v pgrep"
    assert trace_text =~ "command -v ps"
    assert trace_text =~ "ps -e -o pid= -o ppid="
    assert trace_text =~ ~s|collect_tree_pids "$tree_child"|
    assert trace_text =~ "kill_tree TERM $tree_pids"
    refute trace_text =~ "remote prompt"
    refute trace_text =~ "ssh-mcp-secret"
    assert File.read!(trace <> ".prompt") == "remote prompt"
    assert File.read!(trace <> ".mcp") =~ "ssh-mcp-secret"
    assert File.read!(trace <> ".claude") =~ "SECRET:unset"
    assert_temp_paths_removed!(trace <> ".paths", :ssh)
  end

  test "SSH worker 启动失败保持 typed startup error，不回退本地", context do
    previous_path = System.get_env("PATH")
    empty_bin = Path.join(context.test_root, "empty-ssh-bin")
    File.mkdir_p!(empty_bin)
    System.put_env("PATH", empty_bin)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: "/missing/claude"
    )

    assert {:error,
            %Error{
              kind: :startup,
              raw: {:invalid_workspace_cwd, :remote_validation_unavailable, "worker-a", :ssh_not_found}
            }} = ClaudeCodeBackend.start_session(context.workspace, worker_host: "worker-a")
  end

  test "每轮重新 canonicalize 本地 workspace，start 后 symlink escape fail closed", context do
    invoked = Path.join(context.test_root, "local-workspace-invoked")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        touch #{shell_literal(invoked)}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "workspace-recheck"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    outside = Path.join(context.test_root, "outside-after-start")
    File.mkdir_p!(outside)
    File.rm_rf!(context.workspace)
    File.ln_s!(outside, context.workspace)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :symlink_escape, _, _}}} =
             ClaudeCodeBackend.run_turn(session, "escape", context.issue)

    refute File.exists?(invoked)
  end

  test "SSH 启动脚本 canonicalize workspace/root，远端 symlink escape 以 126 fail closed", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "canonical-ssh-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    remote_root = Path.join(context.test_root, "remote-root")
    remote_workspace = Path.join(remote_root, "REMOTE-1")
    outside = Path.join(context.test_root, "remote-outside")
    File.mkdir_p!(remote_root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, remote_workspace)

    invoked = Path.join(context.test_root, "remote-workspace-invoked")
    fake_claude = install_fake_claude!(context.test_root, "#!/bin/sh\ntouch #{shell_literal(invoked)}\ncat >/dev/null\n", "remote-guard")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: remote_root,
      agent_backend: "claude_code",
      claude_code_command: fake_claude
    )

    assert {:error,
            %Error{
              kind: :startup,
              raw: {:invalid_workspace_cwd, :remote_validation_failed, "worker-a", 43, _diagnostic}
            }} = ClaudeCodeBackend.start_session(remote_workspace, worker_host: "worker-a")

    refute File.exists?(invoked)
  end

  test "SSH workspace/root 展开 tilde 后 canonicalize 并运行", context do
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    fake_bin = Path.join(context.test_root, "tilde-ssh-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    fake_home = Path.join(context.test_root, "remote-home")
    remote_root = Path.join(fake_home, "remote-root")
    remote_workspace = Path.join(remote_root, "REMOTE-TILDE")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(remote_workspace)

    File.write!(fake_ssh, """
    #!/bin/sh
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.put_env("HOME", fake_home)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("HOME", previous_home)
    end)

    fake_claude =
      install_fake_claude!(
        context.test_root,
        "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"session_id\":\"#{@provider_session_1}\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'\n",
        "remote-tilde"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "~/remote-root",
      agent_backend: "claude_code",
      claude_code_command: fake_claude
    )

    assert {:ok, session} = ClaudeCodeBackend.start_session("~/remote-root/REMOTE-TILDE", worker_host: "worker-a")
    assert {:ok, result} = ClaudeCodeBackend.run_turn(session, "tilde", context.issue)
    assert result.session.session_id == @provider_session_1
  end

  test "可选 CLI flags 支持关闭 partial、空 model、字符串 MCP 且无 tracker secret", context do
    trace = Path.join(context.test_root, "optional.trace")

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        printf 'ARGV:' > #{shell_literal(trace)}
        for arg in "$@"; do printf '%s|' "$arg" >> #{shell_literal(trace)}; done
        printf '\n' >> #{shell_literal(trace)}
        cat >/dev/null
        printf '%s\n' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
        """,
        "optional"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_model: "",
      claude_code_include_partial_messages: false,
      claude_code_mcp_config: "/tmp/claude-mcp.json"
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    assert {:ok, _result} = ClaudeCodeBackend.run_turn(session, "optional", context.issue)

    argv = File.read!(trace)
    refute argv =~ "--include-partial-messages"
    refute argv =~ "--model"
    assert argv =~ "--mcp-config|/tmp/claude-mcp.json"
  end

  test "bash 缺失和无效 cwd 都映射 startup error", context do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: "claude"
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", context.test_root)

    try do
      assert {:error, %Error{kind: :startup, raw: :bash_not_found}} =
               ClaudeCodeBackend.run_turn(session, "missing bash", context.issue)
    after
      restore_env("PATH", previous_path)
    end

    invalid_session = %{session | workspace: <<0>>}

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :path_unreadable, _, :badarg}}} =
             ClaudeCodeBackend.run_turn(invalid_session, "bad cwd", context.issue)

    invalid_command_session = put_in(session.runtime_settings.command, <<0>>)

    assert {:error, %Error{kind: :startup, raw: {:port_open_failed, _}}} =
             ClaudeCodeBackend.run_turn(invalid_command_session, "bad command", context.issue)
  end

  test "大 stream frame、tool/user/generic records 和无 subtype result 都会归一化", context do
    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"tool_use","name":"Read"}'
        printf '%s\n' '{"type":"system","message":"ready"}'
        printf '%s\n' '{"type":"assistant","message":{"content":"plain"}}'
        printf '%s' '{"type":"assistant","message":{"content":[{"type":"text","text":"'
        head -c 200000 /dev/zero | tr '\\000' a
        printf '%s\n' '"}]}}'
        printf '%s' '{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":2}}'
        """,
        "large-stream"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 15_000
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:ok, result} =
             ClaudeCodeBackend.run_turn(session, "large", context.issue, on_message: &send(test_pid, {:event, &1}))

    assert result.session.session_id == @provider_session_1
    assert_received {:event, %Event{type: :tool_activity, payload: %{"type" => "tool_use"}}}
    assert_received {:event, %Event{type: :notification, payload: %{"type" => "system"}}}
    assert_received {:event, %Event{type: :notification, payload: %{"type" => "assistant"}}}
  end

  test "恰好一个 port chunk 的无换行 result 会在 process exit 时完成解析", context do
    prefix =
      ~s|{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1},"padding":"|

    suffix = ~s|"}|
    padding_bytes = 200_000 - byte_size(prefix) - byte_size(suffix)

    fake =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s' #{shell_literal(prefix)}
        head -c #{padding_bytes} /dev/zero | tr '\\000' a
        printf '%s' #{shell_literal(suffix)}
        """,
        "boundary-no-eol"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    assert {:ok, result} = ClaudeCodeBackend.run_turn(session, "boundary", context.issue)
    assert result.session.session_id == @provider_session_1
  end

  test "result error variants、missing result 和 provider error shapes 保留 typed 语义", context do
    cases = [
      {"result-error", ~s|printf '%s\\n' '{"type":"result","is_error":true,"error":"temporary unavailable"}'|, :provider, :provider_error, true},
      {"code-error", ~s|printf '%s\\n' '{"type":"error","error":{"code":"fatal","message":"bad"}}'|, :provider, "fatal", false},
      {"inspect-error", ~s|printf '%s\\n' '{"type":"error","error":{"unexpected":1}}'|, :provider, :provider_error, false},
      {"missing-result", ":", :protocol, :missing_result, false}
    ]

    Enum.each(cases, fn {name, body, kind, code, retryable?} ->
      fake = install_fake_claude!(context.test_root, "#!/bin/sh\ncat >/dev/null\n#{body}\n", name)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

      assert {:error, %Error{kind: ^kind, code: ^code, retryable?: ^retryable?}} =
               ClaudeCodeBackend.run_turn(session, name, context.issue)
    end)
  end

  test "合法 JSON 非对象 frame 映射为不可重试 protocol error", context do
    fake =
      install_fake_claude!(
        context.test_root,
        "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '[]'\n",
        "non-object-json"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :protocol, code: :non_object_frame, retryable?: false}} =
             ClaudeCodeBackend.run_turn(session, "non-object", context.issue, on_message: &send(test_pid, {:event, &1}))

    assert_received {:event,
                     %Event{
                       type: :malformed_protocol,
                       error: %Error{code: :non_object_frame}
                     }}
  end

  test "terminal result/error frame 立即收敛并由 cleanup 终止未退出进程", context do
    cases = [
      {:success, ~s|{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}|},
      {:error, ~s|{"type":"error","error":{"code":"fatal","message":"stop now"}}|}
    ]

    Enum.each(cases, fn {name, frame} ->
      fake =
        install_fake_claude!(
          context.test_root,
          "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' #{shell_literal(frame)}\nsleep 3\n",
          "terminal-immediate-#{name}"
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake,
        claude_code_turn_timeout_ms: 1_600
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
      started = System.monotonic_time(:millisecond)
      result = ClaudeCodeBackend.run_turn(session, "terminal", context.issue)
      elapsed_ms = System.monotonic_time(:millisecond) - started

      case name do
        :success -> assert {:ok, %{session_id: @provider_session_1}} = result
        :error -> assert {:error, %Error{kind: :provider, code: "fatal"}} = result
      end

      assert elapsed_ms < 1_300
    end)
  end

  test "terminal error 不会被后续 success 覆盖，result session_id 必须为非空字符串", context do
    cases = [
      {"malformed-then-success", "printf '%s\\n' '{\"type\":\"result\"' '{\"type\":\"result\",\"session_id\":\"#{@provider_session_1}\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'",
       :protocol, :malformed_json},
      {"error-then-success",
       "printf '%s\\n' '{\"type\":\"error\",\"error\":{\"code\":\"fatal\",\"message\":\"first failure\"}}' '{\"type\":\"result\",\"session_id\":\"#{@provider_session_1}\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'",
       :provider, "fatal"},
      {"error-then-exit", "printf '%s\\n' '{\"type\":\"error\",\"error\":{\"code\":\"fatal\",\"message\":\"first failure\"}}'; exit 23", :provider, "fatal"},
      {"missing-session", "printf '%s\\n' '{\"type\":\"result\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'", :protocol, :invalid_session_id},
      {"blank-session", "printf '%s\\n' '{\"type\":\"result\",\"session_id\":\"  \",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'", :protocol, :invalid_session_id},
      {"control-session", "printf '%s\\n' '{\"type\":\"result\",\"session_id\":\"11111111-1111-4111-8111-11111111111\\u0000\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'", :protocol,
       :invalid_session_id}
    ]

    Enum.each(cases, fn {name, body, kind, code} ->
      fake = install_fake_claude!(context.test_root, "#!/bin/sh\ncat >/dev/null\n#{body}\n", name)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake
      )

      {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
      test_pid = self()

      assert {:error, %Error{kind: ^kind, code: ^code}} =
               ClaudeCodeBackend.run_turn(session, name, context.issue, on_message: &send(test_pid, {name, &1}))

      refute_received {^name, %Event{type: :turn_completed}}
    end)
  end

  test "失败 result 保留 usage，usage/config/command exit 不可重试", context do
    failure =
      install_fake_claude!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"result","is_error":true,"error":{"code":"bad_request","message":"invalid"},"session_id":"#{@provider_session_1}","usage":{"input_tokens":9,"output_tokens":4,"cache_read_input_tokens":2}}'
        """,
        "failure-usage"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: failure
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :provider}} =
             ClaudeCodeBackend.run_turn(session, "failure", context.issue, on_message: &send(test_pid, {:failure_event, &1}))

    assert_received {:failure_event,
                     %Event{
                       type: :turn_failed,
                       usage: %Usage{input_tokens: 9, output_tokens: 4, cache_read_input_tokens: 2}
                     }}

    Enum.each([1, 64, 78, 126, 127], fn status ->
      fake = install_fake_claude!(context.test_root, "#!/bin/sh\ncat >/dev/null\nexit #{status}\n", "exit-#{status}")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: context.workspace_root,
        agent_backend: "claude_code",
        claude_code_command: fake
      )

      {:ok, exit_session} = ClaudeCodeBackend.start_session(context.workspace)

      assert {:error, %Error{kind: :process_exit, code: ^status, retryable?: false}} =
               ClaudeCodeBackend.run_turn(exit_session, "exit", context.issue)
    end)
  end

  test "WorkspaceGuard 两参数入口覆盖本地/SSH canonical root，并透传远端错误", context do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: context.workspace_root)

    assert {:ok, local_workspace} = WorkspaceGuard.validate(context.workspace, nil)
    assert local_workspace == PathSafety.canonicalize(context.workspace) |> elem(1)
    assert {:ok, ^local_workspace} = WorkspaceGuard.validate(context.workspace, nil, "/")

    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "workspace-guard-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    assert {:ok, remote_workspace} = WorkspaceGuard.validate(context.workspace, "worker-a")
    assert remote_workspace == local_workspace

    assert {:ok, %{workspace: ^local_workspace, workspace_root: "/"}} =
             WorkspaceGuard.validate_remote(context.workspace, "worker-a", "/")

    assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "worker-a"}} =
             WorkspaceGuard.validate(" ", "worker-a", context.workspace_root)
  end

  test "SSH turn validation 成功后 ssh 消失时返回 startup error", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "vanishing-ssh-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    counter = Path.join(context.test_root, "vanishing-ssh.count")
    File.mkdir_p!(fake_bin)
    File.ln_s!(System.find_executable("bash"), Path.join(fake_bin, "bash"))

    File.write!(fake_ssh, """
    #!/bin/sh
    count=0
    [ -f #{shell_literal(counter)} ] && read count < #{shell_literal(counter)}
    count=$((count + 1))
    printf '%s' "$count" > #{shell_literal(counter)}
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    status=$?
    [ "$count" -eq 2 ] && /bin/rm -f "$0"
    exit "$status"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: "/missing/claude"
    )

    assert {:ok, session} = ClaudeCodeBackend.start_session(context.workspace, worker_host: "worker-a")

    assert {:error, %Error{kind: :startup, raw: :ssh_not_found}} =
             ClaudeCodeBackend.run_turn(session, "ssh disappeared", context.issue)

    refute File.exists?(fake_ssh)
  end

  test "synthetic Port frames 覆盖 receive 与 post-exit drain 的 noeol/eol 边界", context do
    {oversize_task, oversize_port} = start_silent_turn!(context, "synthetic-oversize")
    send(oversize_task.pid, {oversize_port, {:data, {:noeol, "x"}}})
    send(oversize_task.pid, {oversize_port, {:data, {:eol, String.duplicate("a", @max_stream_frame_bytes)}}})

    assert {:error, %Error{kind: :protocol, code: :frame_too_large}} =
             Task.await(oversize_task, 10_000)

    {drain_task, drain_port} = start_silent_turn!(context, "synthetic-drain")

    assistant = ~s|{"type":"assistant","message":{"content":"after-exit"}}|

    result =
      ~s|{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}|

    send(drain_task.pid, {drain_port, {:exit_status, 0}})
    send(drain_task.pid, {drain_port, {:data, {:eol, assistant}}})
    send(drain_task.pid, {drain_port, {:data, {:noeol, result}}})

    assert {:ok, %{session_id: @provider_session_1}} = Task.await(drain_task, 10_000)

    {drain_oversize_task, drain_oversize_port} = start_silent_turn!(context, "synthetic-drain-oversize")
    drain_oversize_frame = String.duplicate("b", @max_stream_frame_bytes + 1)
    send(drain_oversize_task.pid, {drain_oversize_port, {:exit_status, 0}})
    send(drain_oversize_task.pid, {drain_oversize_port, {:data, {:eol, drain_oversize_frame}}})

    assert {:error, %Error{kind: :protocol, code: :frame_too_large}} =
             Task.await(drain_oversize_task, 10_000)

    {terminal_task, terminal_port} = start_silent_turn!(context, "synthetic-terminal-drain")
    terminal_error = ~s|{"type":"error","error":{"code":"fatal","message":"first"}}|

    terminal_success =
      ~s|{"type":"result","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}|

    send(terminal_task.pid, {terminal_port, {:exit_status, 23}})
    send(terminal_task.pid, {terminal_port, {:data, {:eol, terminal_error}}})
    send(terminal_task.pid, {terminal_port, {:data, {:eol, terminal_success}}})

    assert {:error, %Error{kind: :provider, code: "fatal"}} =
             Task.await(terminal_task, 10_000)
  end

  test "Port cleanup 在系统工具缺失时仍关闭真实 child port", context do
    previous_path = System.get_env("PATH")
    {task, port} = start_silent_turn!(context, "missing-process-tools")
    System.put_env("PATH", context.test_root)

    try do
      send(task.pid, {:agent_cancel, :missing_process_tools})

      assert {:error, %Error{kind: :cancelled, code: :missing_process_tools}} =
               Task.await(task, 10_000)

      assert :undefined == :erlang.port_info(port)
    after
      restore_env("PATH", previous_path)
    end
  end

  test "Port cleanup 使用可发现 pgrep/kill，解析坏 PID 并执行 TERM 到 KILL", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "process-tools-bin")
    pgrep_count = Path.join(context.test_root, "pgrep.count")
    ps_trace = Path.join(context.test_root, "ps.trace")
    kill_trace = Path.join(context.test_root, "kill.trace")
    File.mkdir_p!(fake_bin)

    File.write!(Path.join(fake_bin, "pgrep"), """
    #!/bin/sh
    count=0
    [ -f #{shell_literal(pgrep_count)} ] && count="$(cat #{shell_literal(pgrep_count)})"
    count=$((count + 1))
    printf '%s' "$count" > #{shell_literal(pgrep_count)}
    if [ "$count" -eq 1 ]; then
      printf '%s\n' '424242' 'not-a-pid'
      exit 0
    fi
    exit 1
    """)

    File.write!(Path.join(fake_bin, "ps"), """
    #!/bin/sh
    touch #{shell_literal(ps_trace)}
    exit 0
    """)

    File.write!(Path.join(fake_bin, "kill"), """
    #!/bin/sh
    printf '%s\n' "$*" >> #{shell_literal(kill_trace)}
    exit 0
    """)

    File.chmod!(Path.join(fake_bin, "pgrep"), 0o755)
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    File.chmod!(Path.join(fake_bin, "kill"), 0o755)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    {task, port} = start_silent_turn!(context, "fake-process-tools")
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    send(task.pid, {:agent_cancel, :process_tree_cleanup})

    assert {:error, %Error{kind: :cancelled, code: :process_tree_cleanup}} =
             Task.await(task, 10_000)

    trace = File.read!(kill_trace)
    assert trace =~ "-TERM"
    assert trace =~ "-0"
    assert trace =~ "-KILL"
    refute File.exists?(ps_trace)
    assert :undefined == :erlang.port_info(port)
  end

  test "远端 shell 在 pgrep 执行失败时用 ps 捕获进程树并升级到 KILL", context do
    fake_bin = Path.join(context.test_root, "remote-ps-bin")
    kill_trace = Path.join(context.test_root, "remote-kill.trace")
    sleep_trace = Path.join(context.test_root, "remote-sleep.trace")
    File.mkdir_p!(fake_bin)

    File.write!(Path.join(fake_bin, "pgrep"), "#!/bin/sh\nexit 2\n")

    File.write!(Path.join(fake_bin, "ps"), """
    #!/bin/sh
    printf '%s\n' 'PID PPID' '200 100' '300 200' 'bad row'
    """)

    File.write!(Path.join(fake_bin, "sleep"), """
    #!/bin/sh
    printf '%s\n' "$*" >> #{shell_literal(sleep_trace)}
    """)

    File.chmod!(Path.join(fake_bin, "pgrep"), 0o755)
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    File.chmod!(Path.join(fake_bin, "sleep"), 0o755)

    script = """
    kill() { printf '%s %s\n' "$1" "$2" >> #{shell_literal(kill_trace)}; }
    #{ClaudeCodeBackend.process_tree_command()}
    agent_pid=100
    terminate_agent
    """

    assert {"", 0} =
             System.cmd("/bin/bash", ["-c", script], env: [{"PATH", fake_bin}], stderr_to_stdout: true)

    assert File.read!(kill_trace) ==
             "-TERM 300\n-TERM 200\n-TERM 100\n" <>
               "-0 300\n-KILL 300\n-0 200\n-KILL 200\n-0 100\n-KILL 100\n"

    assert File.read!(sleep_trace) == "0.25\n"
  end

  test "Port cleanup 在 pgrep 执行失败时用 ps 递归发现 child 和 grandchild", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "ps-process-tools-bin")
    kill_trace = Path.join(context.test_root, "ps-kill.trace")
    File.mkdir_p!(fake_bin)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    {task, port} = start_silent_turn!(context, "fake-ps-process-tools")
    root_pid = ClaudeCodeBackend.port_process_id(port)
    child_pid = 424_242
    grandchild_pid = 434_343

    File.write!(Path.join(fake_bin, "pgrep"), "#!/bin/sh\nexit 2\n")

    File.write!(Path.join(fake_bin, "ps"), """
    #!/bin/sh
    printf '%s\n' 'PID PPID' '#{child_pid} #{root_pid}' '#{grandchild_pid} #{child_pid}' 'bad row'
    """)

    File.write!(Path.join(fake_bin, "kill"), """
    #!/bin/sh
    printf '%s\n' "$*" >> #{shell_literal(kill_trace)}
    exit 0
    """)

    File.chmod!(Path.join(fake_bin, "pgrep"), 0o755)
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    File.chmod!(Path.join(fake_bin, "kill"), 0o755)
    System.put_env("PATH", fake_bin)
    send(task.pid, {:agent_cancel, :ps_process_tree_cleanup})

    assert {:error, %Error{kind: :cancelled, code: :ps_process_tree_cleanup}} =
             Task.await(task, 10_000)

    trace = File.read!(kill_trace)

    Enum.each([grandchild_pid, child_pid, String.to_integer(root_pid)], fn pid ->
      assert trace =~ "-TERM #{pid}"
      assert trace =~ "-KILL #{pid}"
    end)

    assert :undefined == :erlang.port_info(port)
  end

  test "Port cleanup 在 pgrep 与 ps 都失败时仍终止根进程", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "failed-process-tools-bin")
    kill_trace = Path.join(context.test_root, "failed-process-kill.trace")
    File.mkdir_p!(fake_bin)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    {task, port} = start_silent_turn!(context, "failed-process-tools")
    root_pid = ClaudeCodeBackend.port_process_id(port)

    File.write!(Path.join(fake_bin, "pgrep"), "#!/bin/sh\nexit 2\n")
    File.write!(Path.join(fake_bin, "ps"), "#!/bin/sh\nexit 2\n")

    File.write!(Path.join(fake_bin, "kill"), """
    #!/bin/sh
    printf '%s\n' "$*" >> #{shell_literal(kill_trace)}
    exit 0
    """)

    File.chmod!(Path.join(fake_bin, "pgrep"), 0o755)
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    File.chmod!(Path.join(fake_bin, "kill"), 0o755)
    System.put_env("PATH", fake_bin)
    send(task.pid, {:agent_cancel, :failed_process_discovery})

    assert {:error, %Error{kind: :cancelled, code: :failed_process_discovery}} =
             Task.await(task, 10_000)

    trace = File.read!(kill_trace)
    assert trace =~ "-TERM #{root_pid}"
    assert trace =~ "-KILL #{root_pid}"
    assert :undefined == :erlang.port_info(port)
  end

  test "internal Port cleanup 支持 non-OS driver 与无效 Port term" do
    driver_port = Port.open({:spawn_driver, ~c"ram_file_drv"}, [:binary])
    assert nil == ClaudeCodeBackend.port_process_id(driver_port)
    send(self(), {driver_port, {:exit_status, 0}})
    assert :ok = ClaudeCodeBackend.stop_port(driver_port)
    assert :undefined == :erlang.port_info(driver_port)
    assert :ok = ClaudeCodeBackend.close_port(:not_a_port)
  end

  test "stop_session 幂等" do
    assert :ok = ClaudeCodeBackend.stop_session(%{backend: :claude_code})
    assert :ok = ClaudeCodeBackend.stop_session(%{backend: :claude_code})
  end

  defp install_fake_claude!(test_root, script, suffix \\ "default") do
    path = Path.join(test_root, "fake-claude-#{suffix}")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp start_silent_turn!(context, suffix) do
    ready_path = Path.join(context.test_root, "#{suffix}.ready")

    fake =
      install_fake_claude!(
        context.test_root,
        "#!/bin/sh\ntouch #{shell_literal(ready_path)}\ncat >/dev/null\nsleep 10\n",
        suffix
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "claude_code",
      claude_code_command: fake,
      claude_code_turn_timeout_ms: 20_000
    )

    {:ok, session} = ClaudeCodeBackend.start_session(context.workspace)

    task =
      Task.async(fn ->
        ClaudeCodeBackend.run_turn(session, suffix, context.issue)
      end)

    port = wait_for_linked_port!(task.pid)
    assert wait_until(fn -> File.exists?(ready_path) end)
    {task, port}
  end

  defp wait_for_linked_port!(pid, attempts \\ 200)
  defp wait_for_linked_port!(_pid, 0), do: flunk("Claude turn did not open a Port")

  defp wait_for_linked_port!(pid, attempts) do
    port =
      case Process.info(pid, :links) do
        {:links, links} -> Enum.find(links, &is_port/1)
        _ -> nil
      end

    if is_port(port) do
      port
    else
      Process.sleep(10)
      wait_for_linked_port!(pid, attempts - 1)
    end
  end

  defp success_script(trace) do
    """
    #!/bin/sh
    trace="${SYMP_CLAUDE_TRACE:-#{trace}}"
    printf 'PREFIX:%s\n' "${CLAUDE_PREFIX:-missing}" >> "$trace"
    printf 'SECRET:%s\n' "${LINEAR_API_KEY:-unset}" >> "$trace"
    printf 'ARGV:' >> "$trace"
    for arg in "$@"; do printf '%s|' "$arg" >> "$trace"; done
    printf '\n' >> "$trace"
    cat > "$trace.prompt"
    prompt_path="${SYMPHONY_CLAUDE_PROMPT_FILE:-}"
    printf '%s\n' "$prompt_path" > "$trace.prompt_path"
    printf '%s\n' "${SYMPHONY_CLAUDE_STDERR_FILE:-}" > "$trace.stderr_path"
    stat -f '%Lp' "$prompt_path" > "$trace.mode" 2>/dev/null || stat -c '%a' "$prompt_path" > "$trace.mode"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}'
    """
  end

  defp resume_script(trace) do
    """
    #!/bin/sh
    printf 'ARGV:' >> #{shell_literal(trace)}
    for arg in "$@"; do printf '%s|' "$arg" >> #{shell_literal(trace)}; done
    printf '\n' >> #{shell_literal(trace)}
    cat >/dev/null
    count_file=#{shell_literal(trace <> ".count")}
    count=0
    [ -f "$count_file" ] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then session_id=#{shell_literal(@provider_session_1)}; else session_id=#{shell_literal(@provider_session_2)}; fi
    printf '{"type":"result","subtype":"success","session_id":"%s","usage":{"input_tokens":1,"output_tokens":1}}\n' "$session_id"
    """
  end

  defp assert_temp_paths_removed!(path_file, label) do
    paths = path_file |> File.read!() |> String.split("\n", trim: true)
    assert length(paths) == 3
    assert Enum.all?(paths, &(String.trim(&1) != ""))

    temporary_paths = Enum.reject(paths, &(&1 == "/dev/null" or &1 == "unused"))

    assert wait_until(fn -> Enum.all?(temporary_paths, &(not File.exists?(&1))) end),
           "#{label} temporary files leaked: #{inspect(Enum.filter(temporary_paths, &File.exists?/1))}"
  end

  defp os_process_alive?(pid) when is_integer(pid) do
    case System.find_executable("kill") do
      nil -> false
      executable -> match?({_output, 0}, System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
    end
  end

  defp wait_until(predicate, attempts \\ 100)
  defp wait_until(_predicate, 0), do: false

  defp wait_until(predicate, attempts) when is_function(predicate, 0) do
    if predicate.() do
      true
    else
      Process.sleep(20)
      wait_until(predicate, attempts - 1)
    end
  end

  defp shell_literal(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
