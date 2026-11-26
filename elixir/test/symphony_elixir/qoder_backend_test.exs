defmodule SymphonyElixir.QoderBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentServer.{Error, Event, Usage}
  alias SymphonyElixir.QoderBackend

  @provider_session_1 "11111111-1111-4111-8111-111111111111"
  @provider_session_2 "22222222-2222-4222-8222-222222222222"

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-qoder-backend-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "QODER-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "qoder-issue-1",
      identifier: "QODER-1",
      title: "Qoder backend",
      description: "test",
      state: "In Progress",
      url: "https://example.test/QODER-1",
      labels: [],
      dispatchable: true
    }

    %{test_root: test_root, workspace_root: workspace_root, workspace: workspace, issue: issue}
  end

  test "start_session 使用合法 UUID 并拒绝非法 workspace", context do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder"
    )

    assert {:ok, session} = QoderBackend.start_session(context.workspace)
    assert session.backend == :qoder
    assert session.turn_count == 0
    assert String.match?(session.session_id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :workspace_root, _}}} =
             QoderBackend.start_session(context.workspace_root)

    outside = Path.join(context.test_root, "outside")
    File.mkdir_p!(outside)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :outside_workspace_root, _, _}}} =
             QoderBackend.start_session(outside)

    assert {:error, %Error{kind: :startup, raw: {:invalid_workspace_cwd, :empty_remote_workspace, "worker-a"}}} =
             QoderBackend.start_session(" ", worker_host: "worker-a")
  end

  test "本地 Qoder turn 使用安全 stdin framing、kebab/snake flag、剥离 secret 并返回真实 session", context do
    trace = Path.join(context.test_root, "qoder.trace")
    fake = install_fake_qoder!(context.test_root, success_script(trace))
    previous_trace = System.get_env("SYMP_QODER_TRACE")
    previous_secret = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("SYMP_QODER_TRACE", previous_trace)
      restore_env("LINEAR_API_KEY", previous_secret)
    end)

    System.put_env("SYMP_QODER_TRACE", trace)
    System.put_env("LINEAR_API_KEY", "must-not-leak")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: "env QODER_PREFIX=present #{fake}",
      qoder_model: "auto",
      qoder_permission_mode: "accept_edits",
      qoder_reasoning_effort: "high",
      qoder_allowed_tools: ["Read", "Edit"],
      qoder_disallowed_tools: ["Bash"],
      qoder_mcp_config: %{"mcpServers" => %{}}
    )

    prompt = "do the task 'safely'\n"
    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()

    assert {:ok, result} =
             QoderBackend.run_turn(session, prompt, context.issue, on_message: &send(test_pid, {:qoder_event, &1}))

    assert result.session.session_id == @provider_session_1
    assert result.session.resume_session_id == @provider_session_1
    assert result.session.turn_count == 1

    assert_received {:qoder_event, %Event{backend: :qoder, type: :session_started, process_id: process_id}}
    assert is_binary(process_id) and process_id != ""
    assert_received {:qoder_event, %Event{type: :notification, payload: %{"type" => "assistant"}}}

    assert_received {:qoder_event,
                     %Event{
                       type: :turn_completed,
                       session_id: @provider_session_1,
                       usage: %Usage{mode: :delta, scope: :turn, input_tokens: 12, output_tokens: 5}
                     }}

    trace_text = File.read!(trace)
    assert trace_text =~ "PREFIX:present"
    assert trace_text =~ "SECRET:unset"
    assert trace_text =~ "--print"
    assert trace_text =~ "--output-format|stream-json"
    assert trace_text =~ "--session-id|#{session.session_id}"
    assert trace_text =~ "--model|auto"
    assert trace_text =~ "--permission-mode|accept_edits"
    assert trace_text =~ "--reasoning-effort|high"
    assert trace_text =~ "--allowed-tools|Read"
    assert trace_text =~ "--disallowed-tools|Bash"
    assert trace_text =~ "--setting-sources|user"
    assert trace_text =~ "--strict-mcp-config"
    refute trace_text =~ "--verbose"
    refute trace_text =~ "--include-partial-messages"
    refute trace_text =~ "--allowedTools|"
    assert File.read!(trace <> ".prompt") == prompt
    assert File.read!(trace <> ".mode") |> String.trim() == "600"
  end

  test "第二轮通过 --resume 延续 provider session", context do
    fake = install_fake_qoder!(context.test_root, resume_script())

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    assert {:ok, result} = QoderBackend.run_turn(session, "first", context.issue)
    assert result.session.resume_session_id == @provider_session_1

    assert {:ok, result2} = QoderBackend.run_turn(result.session, "second", context.issue)
    assert result2.session.turn_count == 2
    assert result2.session.session_id == @provider_session_2
  end

  test "父环境 nesting marker 被剥离，子进程不继承", context do
    trace = Path.join(context.test_root, "marker.trace")
    fake = install_fake_qoder!(context.test_root, marker_script(trace))
    previous = System.get_env("QODER_AGENT_SDK_ENTRYPOINT")

    on_exit(fn -> restore_env("QODER_AGENT_SDK_ENTRYPOINT", previous) end)
    System.put_env("QODER_AGENT_SDK_ENTRYPOINT", "1")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    assert {:ok, _result} = QoderBackend.run_turn(session, "go", context.issue)
    assert File.read!(trace) =~ "MARKER:unset"
  end

  test "result is_error 映射 turn_failed", context do
    fake =
      install_fake_qoder!(context.test_root, """
      #!/bin/sh
      cat >/dev/null
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"#{@provider_session_1}","error":{"type":"rate_limit","message":"429 too many requests"}}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :provider, retryable?: true}} =
             QoderBackend.run_turn(session, "go", context.issue, on_message: &send(test_pid, {:qoder_event, &1}))

    assert_received {:qoder_event, %Event{type: :turn_failed}}
  end

  test "permission_denials 映射 approval_required blocked", context do
    fake =
      install_fake_qoder!(context.test_root, """
      #!/bin/sh
      cat >/dev/null
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","permission_denials":[{"tool":"Bash"}]}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :approval_required, blocked?: true}} =
             QoderBackend.run_turn(session, "go", context.issue, on_message: &send(test_pid, {:qoder_event, &1}))

    assert_received {:qoder_event, %Event{type: :approval_required}}
  end

  test "Qoder rate_limits 缺省为 nil（P3）", context do
    fake = install_fake_qoder!(context.test_root, success_script(Path.join(context.test_root, "rl.trace")))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()
    assert {:ok, _} = QoderBackend.run_turn(session, "go", context.issue, on_message: &send(test_pid, {:qoder_event, &1}))
    assert_received {:qoder_event, %Event{type: :turn_completed, rate_limits: nil}}
  end

  test "子进程瞬时退出返回 typed error", context do
    fake =
      install_fake_qoder!(context.test_root, """
      #!/bin/sh
      cat >/dev/null
      exit 3
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    assert {:error, %Error{kind: :process_exit, code: 3}} = QoderBackend.run_turn(session, "go", context.issue)
  end

  test "非法 workspace 在 run_turn 映射 startup_failed", context do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder"
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()
    bad = %{session | workspace: context.workspace_root}

    assert {:error, %Error{kind: :startup}} =
             QoderBackend.run_turn(bad, "go", context.issue, on_message: &send(test_pid, {:qoder_event, &1}))

    assert_received {:qoder_event, %Event{type: :startup_failed}}
  end

  test "mcp_config 字符串路径与 nil 分支", context do
    fake = install_fake_qoder!(context.test_root, success_script(Path.join(context.test_root, "mcp.trace")))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake,
      qoder_mcp_config: "/tmp/qoder-mcp.json"
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    assert {:ok, _} = QoderBackend.run_turn(session, "go", context.issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake,
      qoder_mcp_config: nil,
      qoder_model: nil,
      qoder_permission_mode: "auto",
      qoder_reasoning_effort: nil,
      qoder_allowed_tools: [],
      qoder_disallowed_tools: []
    )

    {:ok, session2} = QoderBackend.start_session(context.workspace)
    assert {:ok, _} = QoderBackend.run_turn(session2, "go", context.issue)
  end

  test "stop_session 返回 ok" do
    assert QoderBackend.stop_session(%{}) == :ok
  end

  test "bash 不可用时 start_port 失败映射 startup_failed", context do
    previous_path = System.get_env("PATH")
    fake_bin = Path.join(context.test_root, "empty-bin")
    File.mkdir_p!(fake_bin)
    System.put_env("PATH", fake_bin)
    on_exit(fn -> restore_env("PATH", previous_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: "qoder"
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    test_pid = self()

    assert {:error, %Error{kind: :startup}} =
             QoderBackend.run_turn(session, "go", context.issue, on_message: &send(test_pid, {:qoder_event, &1}))

    assert_received {:qoder_event, %Event{type: :startup_failed}}
  end

  test "子进程瞬时退出返回 typed error 且不泄漏临时目录", context do
    fake = install_fake_qoder!(context.test_root, "#!/bin/sh\nexit 0\n", "instant-exit")
    temp_glob = Path.join(System.tmp_dir!(), "symphony-qoder-*")
    before = temp_glob |> Path.wildcard() |> MapSet.new()

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)

    assert {:error, %Error{kind: kind, code: code}} = QoderBackend.run_turn(session, "instant", context.issue)
    assert kind in [:process_exit, :protocol]
    assert code in [:port_closed, :missing_result]
    assert MapSet.difference(temp_glob |> Path.wildcard() |> MapSet.new(), before) == MapSet.new()
  end

  test "session_started 回调期间 Port 关闭映射 typed process_exit", context do
    fake = install_fake_qoder!(context.test_root, "#!/bin/sh\ncat >/dev/null\nsleep 10\n", "close-before-input")
    kill = System.find_executable("kill")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)

    on_message = fn
      %Event{type: :session_started, process_id: process_id} when is_binary(process_id) ->
        _ = System.cmd(kill, ["-KILL", process_id], stderr_to_stdout: true)
        Process.sleep(50)

      _event ->
        :ok
    end

    assert {:error, %Error{kind: :process_exit, code: :port_closed, retryable?: true}} =
             QoderBackend.run_turn(session, "closed", context.issue, on_message: on_message)
  end

  test "SSH worker 远端 turn 走同一 framing，process exit 不回退本地", context do
    previous_path = System.get_env("PATH")
    trace = Path.join(context.test_root, "ssh.trace")

    fake_qoder =
      install_fake_qoder!(
        context.test_root,
        """
        #!/bin/sh
        cat >/dev/null
        printf 'remote stderr diagnostic\\n' >&2
        exit 31
        """,
        "remote"
      )

    fake_bin = Path.join(context.test_root, "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> #{shell_literal(trace)}
    last=''
    for arg in "$@"; do last="$arg"; done
    eval "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/",
      agent_backend: "qoder",
      qoder_command: fake_qoder
    )

    assert {:ok, session} = QoderBackend.start_session(context.workspace, worker_host: "worker-a:2222")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %Error{kind: :process_exit, code: 31}} =
                 QoderBackend.run_turn(session, "remote prompt", context.issue)
      end)

    assert log =~ "Qoder stderr diagnostic (worker-a:2222"
    assert File.read!(trace) =~ "ARGV:"
  end

  test "mcp_config inline JSON 字符串与空 model 分支", context do
    trace = Path.join(context.test_root, "inline.trace")
    fake = install_fake_qoder!(context.test_root, success_script(trace))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      agent_backend: "qoder",
      qoder_command: fake,
      qoder_model: "",
      qoder_mcp_config: ~s|{"mcpServers":{}}|
    )

    {:ok, session} = QoderBackend.start_session(context.workspace)
    assert {:ok, _} = QoderBackend.run_turn(session, "go", context.issue)

    trace_text = File.read!(trace)
    assert trace_text =~ "--mcp-config|"
    refute trace_text =~ "--model|"
  end

  defp install_fake_qoder!(test_root, script, suffix \\ "default") do
    path = Path.join(test_root, "fake-qoder-#{suffix}")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp shell_literal(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp success_script(trace) do
    """
    #!/bin/sh
    trace="${SYMP_QODER_TRACE:-#{trace}}"
    printf 'PREFIX:%s\\n' "${QODER_PREFIX:-missing}" >> "$trace"
    printf 'SECRET:%s\\n' "${LINEAR_API_KEY:-unset}" >> "$trace"
    printf 'ARGV:' >> "$trace"
    for arg in "$@"; do printf '%s|' "$arg" >> "$trace"; done
    printf '\\n' >> "$trace"
    cat > "$trace.prompt"
    prompt_path="${SYMPHONY_QODER_PROMPT_FILE:-}"
    printf '%s\\n' "$prompt_path" > "$trace.prompt_path"
    stat -f '%Lp' "$prompt_path" > "$trace.mode" 2>/dev/null || stat -c '%a' "$prompt_path" > "$trace.mode"
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
    printf '%s\\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}'
    """
  end

  defp resume_script do
    """
    #!/bin/sh
    cat >/dev/null
    for arg in "$@"; do
      if [ "$prev" = "--resume" ]; then printf '%s\\n' "$arg" > "${SYMPHONY_QODER_PROMPT_FILE}.resume"; fi
      prev="$arg"
    done
    if [ -f "${SYMPHONY_QODER_PROMPT_FILE}.resume" ]; then
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_2}","usage":{"input_tokens":1,"output_tokens":1}}'
    else
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
    fi
    """
  end

  defp marker_script(trace) do
    """
    #!/bin/sh
    cat >/dev/null
    printf 'MARKER:%s\\n' "${QODER_AGENT_SDK_ENTRYPOINT:-unset}" > "#{trace}"
    printf '%s\\n' '{"type":"result","subtype":"success","session_id":"#{@provider_session_1}","usage":{"input_tokens":1,"output_tokens":1}}'
    """
  end
end
