defmodule SymphonyElixir.AgentServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentServer
  alias SymphonyElixir.AgentServer.{Approval, Error, Event, Usage}
  alias SymphonyElixir.Config.Schema

  defmodule FakeBackend do
    @behaviour SymphonyElixir.AgentServer

    @impl true
    def start_session(workspace, opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:fake_backend, :started, workspace, opts})
      {:ok, %{owner: owner, workspace: workspace, turn_count: 0, session_id: "initial-session"}}
    end

    @impl true
    def run_turn(session, prompt, issue, opts) do
      turn_count = session.turn_count + 1
      session_id = "provider-session-#{turn_count}"

      event =
        Event.new(:claude_code, :turn_completed,
          session_id: session_id,
          turn_id: "turn-#{turn_count}",
          usage: Usage.delta(:turn, turn_count, turn_count * 2, {:turn, turn_count}),
          payload: %{"prompt" => prompt, "issue_id" => issue.id}
        )

      Keyword.fetch!(opts, :on_message).(event)
      updated_session = %{session | turn_count: turn_count, session_id: session_id}
      send(session.owner, {:fake_backend, :turn, turn_count, session.session_id, prompt})

      {:ok, %{session: updated_session, session_id: session_id, turn_id: "turn-#{turn_count}"}}
    end

    @impl true
    def stop_session(session) do
      send(session.owner, {:fake_backend, :stopped, session.turn_count, session.session_id})
      :ok
    end
  end

  defmodule RunnerFailureBackend do
    @behaviour SymphonyElixir.AgentServer

    @impl true
    def start_session(workspace, opts) do
      owner = Keyword.fetch!(opts, :owner)

      case Keyword.get(opts, :failure_mode) do
        :startup ->
          {:error,
           Error.new(:startup, "backend startup failed",
             code: :startup_failed,
             raw: %{secret: "startup-raw-secret"}
           )}

        failure_mode ->
          {:ok, %{owner: owner, workspace: workspace, failure_mode: failure_mode, session_id: "runner-session"}}
      end
    end

    @impl true
    def run_turn(%{failure_mode: :raise}, _prompt, _issue, _opts) do
      raise "turn exploded raw-secret-value"
    end

    def run_turn(%{failure_mode: :turn_error}, _prompt, _issue, _opts) do
      {:error,
       Error.new(:provider, "backend turn failed",
         code: :turn_failed,
         retryable?: false,
         raw: %{secret: "turn-raw-secret"}
       )}
    end

    @impl true
    def stop_session(session) do
      send(session.owner, {:runner_failure_backend, :stopped, session.failure_mode})
      :ok
    end
  end

  test "统一事件、usage、error 和 approval contract 保留 typed 语义" do
    usage = Usage.delta(:turn, 3, 2, {:claude_result, "session-1", 1}, cache_read_input_tokens: 1)

    approval =
      Approval.new(:tool, :required,
        request_id: "approval-1",
        decision: nil,
        auto_approved?: false,
        raw: %{"tool" => "Bash"}
      )

    error =
      Error.new(:approval_required, "permission denied",
        code: "permission_denied",
        retryable?: false,
        blocked?: true,
        raw: %{"permission_denials" => [%{"tool_name" => "Bash"}]}
      )

    event =
      Event.new(:claude_code, :approval_required,
        session_id: "session-1",
        turn_id: "turn-1",
        process_id: "123",
        usage: usage,
        approval: approval,
        error: error,
        payload: %{"type" => "result"},
        raw: "{\"type\":\"result\"}"
      )

    assert %Event{backend: :claude_code, type: :approval_required, event: :approval_required} = event
    assert %DateTime{} = event.timestamp
    assert %Usage{mode: :delta, scope: :turn, input_tokens: 3, output_tokens: 2, total_tokens: nil} = event.usage
    assert event.usage.cache_read_input_tokens == 1
    assert %Error{kind: :approval_required, retryable?: false, blocked?: true} = event.error
    assert %Approval{kind: :tool, status: :required, request_id: "approval-1"} = event.approval
  end

  test "统一模型默认构造、process id 和 backend 映射覆盖兼容输入" do
    assert %Usage{mode: :absolute, total_tokens: nil} = Usage.absolute(:thread, nil, nil, :empty)

    assert %Usage{input_tokens: 3, output_tokens: 2, total_tokens: nil} =
             Usage.delta(:turn, 3, 2, :reported_fields_only)

    assert %Usage{total_tokens: 5} =
             Usage.delta(:turn, 3, 2, :reported_total, total_tokens: 5)

    assert %Error{kind: :provider, message: "failed"} = Error.new(:provider, "failed")
    assert %Approval{kind: :tool, status: :required} = Approval.new(:tool, :required)
    assert %Event{backend: :codex, type: :notification} = Event.new(:codex, :notification)
    assert Event.new(:codex, :notification, process_id: 42).process_id == "42"
    assert Event.new(:codex, :notification, process_id: ~c"43").process_id == "43"
    assert Event.new(:codex, :notification, process_id: {:port, 44}).process_id == "{:port, 44}"

    assert AgentServer.backend_module("codex") == SymphonyElixir.Codex.AppServer
    assert AgentServer.backend_module("claude_code") == SymphonyElixir.ClaudeCodeBackend
    assert AgentServer.backend_name(SymphonyElixir.ClaudeCodeBackend) == :claude_code
    assert AgentServer.backend_name(SymphonyElixir.Codex.AppServer) == :codex
  end

  test "backend registry is data-driven and round-trips name↔module" do
    names = AgentServer.backend_names()
    assert :codex in names and :claude_code in names

    for name <- names do
      module = AgentServer.backend_module(name)
      assert AgentServer.backend_module(Atom.to_string(name)) == module
      assert AgentServer.backend_name(module) == name
    end

    assert_raise ArgumentError, fn -> AgentServer.backend_module("nope") end
    assert_raise ArgumentError, fn -> AgentServer.backend_module(:nope) end

    # Unregistered modules (e.g. runner test fakes) keep the :codex fallback.
    assert AgentServer.backend_name(SomeUnknownBackend) == :codex
  end

  test "legacy updates 统一映射 typed usage、error、approval 和兼容 fallback" do
    usage = Usage.delta(:turn, 1, 2, :typed_usage)
    error = Error.new(:provider, "typed error")
    approval = Approval.new(:tool, :required)

    typed =
      AgentServer.normalize_event(:claude_code, %{
        event: :other_message,
        usage: usage,
        error: error,
        approval: approval
      })

    assert typed.type == :notification
    assert typed.usage == usage
    assert typed.error == error
    assert typed.approval == approval

    fallback = AgentServer.normalize_event(:claude_code, %{event: "provider-specific", usage: %{input_tokens: 7}})
    assert fallback.type == :notification
    assert fallback.usage == nil

    Enum.each(
      [
        {"session_started", :session_started},
        {"notification", :notification},
        {"progress", :progress},
        {"tool_activity", :tool_activity},
        {"approval_required", :approval_required},
        {"approval_resolved", :approval_resolved},
        {"input_required", :input_required},
        {"turn_completed", :turn_completed},
        {"turn_failed", :turn_failed},
        {"turn_cancelled", :turn_cancelled},
        {"startup_failed", :startup_failed},
        {"malformed_protocol", :malformed_protocol}
      ],
      fn {event_name, expected_type} ->
        assert AgentServer.normalize_event(:claude_code, %{"event" => event_name}).type == expected_type
      end
    )

    Enum.each(
      [
        {"approval_auto_approved", :approval_resolved},
        {"turn_input_required", :input_required},
        {"malformed", :malformed_protocol},
        {"turn_ended_with_error", :turn_failed},
        {"other_message", :notification}
      ],
      fn {event_name, expected_type} ->
        assert AgentServer.normalize_event(:codex, %{"event" => event_name}).type == expected_type
      end
    )

    assert %Error{kind: :provider, code: :turn_failed, raw: :legacy_failure} =
             AgentServer.normalize_event(:codex, %{event: :turn_ended_with_error, reason: :legacy_failure}).error

    generic_direct_codex =
      AgentServer.normalize_event(:codex, %{
        event: :notification,
        thread_id: "thread-direct",
        usage: %{"input_tokens" => "3", "output_tokens" => 2, "total_tokens" => "5"}
      })

    assert generic_direct_codex.usage == nil

    completed_codex =
      AgentServer.normalize_event(:codex, %{
        event: :turn_completed,
        thread_id: "thread-completed",
        usage: %{"input_tokens" => "3", "output_tokens" => 2, "total_tokens" => "5"}
      })

    assert %Usage{
             mode: :absolute,
             scope: :thread,
             input_tokens: 3,
             output_tokens: 2,
             total_tokens: 5,
             identity: {:codex_usage, :turn_completed, "thread-completed", 3, 2, 5}
           } = completed_codex.usage

    mixed_key_thread_total =
      AgentServer.normalize_event(:codex, %{
        event: :notification,
        thread_id: "thread-mixed",
        payload: %{
          :method => "thread/tokenUsage/updated",
          "params" => %{
            :tokenUsage => %{
              "total" => %{:input_tokens => 8, "output_tokens" => 5, :totalTokens => 13}
            }
          }
        }
      })

    assert %Usage{
             mode: :absolute,
             scope: :thread,
             input_tokens: 8,
             output_tokens: 5,
             total_tokens: 13,
             identity: {:codex_usage, :thread_token_usage_total, "thread-mixed", 8, 5, 13}
           } = mixed_key_thread_total.usage

    no_usage = AgentServer.normalize_event(:codex, %{event: :notification, usage: %{"other" => 1}, payload: "none"})
    assert no_usage.usage == nil

    invalid_number =
      AgentServer.normalize_event(:codex, %{
        event: :turn_completed,
        usage: %{"input_tokens" => "not-a-number", "output_tokens" => 1}
      })

    assert %Usage{input_tokens: nil, output_tokens: 1, total_tokens: nil} = invalid_number.usage

    assert %Error{kind: :provider, code: :turn_failed} =
             AgentServer.normalize_event(:codex, %{event: :turn_failed, payload: :failed}).error

    assert %Error{kind: :cancelled, code: :turn_cancelled} =
             AgentServer.normalize_event(:codex, %{event: :turn_cancelled, payload: :cancelled}).error

    assert %Error{kind: :startup, raw: :startup_reason} =
             AgentServer.normalize_event(:codex, %{event: :startup_failed, reason: :startup_reason}).error

    assert %Approval{kind: :file, status: :resolved, auto_approved?: true} =
             AgentServer.normalize_event(:codex, %{
               event: :approval_auto_approved,
               payload: %{"method" => "item/fileChange/requestApproval"}
             }).approval

    assert %Approval{kind: :mcp, status: :required} =
             AgentServer.normalize_event(:codex, %{
               event: :approval_required,
               payload: %{"method" => "mcpServer/elicitation/request"}
             }).approval

    assert %Approval{kind: :tool, status: :required} =
             AgentServer.normalize_event(:codex, %{event: :approval_required, payload: %{method: "unknown"}}).approval
  end

  test "string-key typed updates 双键读取全部事件字段并按 normalized type 构造模型" do
    timestamp = DateTime.utc_now()
    usage = Usage.delta(:turn, 8, 5, {:claude, "turn-string"}, total_tokens: 13)
    error = Error.new(:provider, "typed string-key failure", code: :typed_failure)

    failed =
      AgentServer.normalize_event(:claude_code, %{
        "event" => "turn_failed",
        "timestamp" => timestamp,
        "session_id" => "session-string",
        "thread_id" => "thread-string",
        "turn_id" => "turn-string",
        "process_id" => 321,
        "usage" => usage,
        "error" => error,
        "payload" => %{"failure" => true},
        "raw" => "raw-string-event",
        "message" => %{"text" => "failed"},
        "display_message" => "display failure",
        "worker_host" => "worker.example",
        "details" => %{"attempt" => 2},
        "rate_limits" => %{"remaining" => 3}
      })

    assert %Event{
             type: :turn_failed,
             event: "turn_failed",
             timestamp: ^timestamp,
             session_id: "session-string",
             thread_id: "thread-string",
             turn_id: "turn-string",
             process_id: "321",
             usage: ^usage,
             error: ^error,
             payload: %{"failure" => true},
             raw: "raw-string-event",
             message: %{"text" => "failed"},
             display_message: "display failure",
             worker_host: "worker.example",
             details: %{"attempt" => 2},
             rate_limits: %{"remaining" => 3}
           } = failed

    required =
      AgentServer.normalize_event(:codex, %{
        "event" => "approval_required",
        "payload" => %{"method" => "item/commandExecution/requestApproval", "id" => "approval-string"}
      })

    assert %Error{kind: :approval_required, blocked?: true} = required.error
    assert %Approval{kind: :command, status: :required, request_id: "approval-string"} = required.approval

    resolved =
      AgentServer.normalize_event(:codex, %{
        "event" => "approval_resolved",
        "payload" => %{"method" => "item/tool/requestUserInput", "id" => "approval-string"},
        "decision" => :approved
      })

    assert resolved.error == nil

    assert %Approval{
             kind: :tool,
             status: :resolved,
             request_id: "approval-string",
             decision: :approved,
             auto_approved?: false
           } = resolved.approval

    codex_usage =
      AgentServer.normalize_event(:codex, %{
        "event" => "turn_completed",
        "thread_id" => "thread-usage-string",
        "usage" => %{"input_tokens" => "4", "output_tokens" => 3, "total_tokens" => "7"}
      })

    assert %Usage{
             mode: :absolute,
             input_tokens: 4,
             output_tokens: 3,
             total_tokens: 7,
             identity: {:codex_usage, :turn_completed, "thread-usage-string", 4, 3, 7}
           } = codex_usage.usage

    assert %Error{kind: :startup, raw: :string_reason} =
             AgentServer.normalize_event(:codex, %{"event" => "startup_failed", "reason" => :string_reason}).error
  end

  test "strict typed maps normalize type、timestamp、usage、error 和 approval structs" do
    event =
      AgentServer.normalize_event(:claude_code, %{
        "type" => "turn_failed",
        "timestamp" => "2026-08-25T01:02:03Z",
        "session_id" => "strict-session",
        "thread_id" => "strict-thread",
        "turn_id" => "strict-turn",
        "process_id" => 42,
        "usage" => %{
          "mode" => "delta",
          "scope" => "turn",
          "input_tokens" => "2",
          "output_tokens" => 1,
          "total_tokens" => "3",
          "cache_read_input_tokens" => "4",
          "cache_creation_input_tokens" => 5,
          "identity" => ["strict", "turn"],
          "raw" => %{"provider" => true}
        },
        "error" => %{
          "kind" => "provider",
          "message" => "retry later",
          "code" => 429,
          "retryable?" => true,
          "blocked?" => false,
          "raw" => %{"provider" => "claude"}
        },
        "approval" => %{
          "kind" => "tool",
          "status" => "required",
          "request_id" => "approval-1",
          "decision" => "pending",
          "auto_approved?" => false,
          "raw" => %{"tool" => "Bash"}
        },
        "payload" => %{"strict" => true}
      })

    assert event.type == :turn_failed
    assert event.event == "turn_failed"
    assert event.timestamp == ~U[2026-08-25 01:02:03Z]
    assert event.process_id == "42"

    assert %Usage{
             mode: :delta,
             scope: :turn,
             input_tokens: 2,
             output_tokens: 1,
             total_tokens: 3,
             cache_read_input_tokens: 4,
             cache_creation_input_tokens: 5,
             identity: ["strict", "turn"],
             raw: %{"provider" => true}
           } = event.usage

    assert %Error{
             kind: :provider,
             message: "retry later",
             code: 429,
             retryable?: true,
             blocked?: false,
             raw: %{"provider" => "claude"}
           } = event.error

    assert %Approval{
             kind: :tool,
             status: :required,
             request_id: "approval-1",
             decision: "pending",
             auto_approved?: false,
             raw: %{"tool" => "Bash"}
           } = event.approval

    atom_values =
      AgentServer.normalize_event(:claude_code, %{
        type: :turn_completed,
        timestamp: 123,
        usage: %{mode: :absolute, scope: :thread, identity: :atom_usage},
        error: %{kind: :protocol, message: :not_a_string},
        approval: %{kind: :command, status: :resolved}
      })

    assert %DateTime{} = atom_values.timestamp
    assert %Usage{mode: :absolute, scope: :thread, identity: :atom_usage} = atom_values.usage
    assert %Error{kind: :protocol, message: ":not_a_string"} = atom_values.error
    assert %Approval{kind: :command, status: :resolved} = atom_values.approval

    string_absolute =
      AgentServer.normalize_event(:claude_code, %{
        "type" => "notification",
        "usage" => %{"mode" => "absolute", "scope" => "thread", "identity" => "string-absolute"}
      })

    atom_delta =
      AgentServer.normalize_event(:claude_code, %{
        type: :notification,
        usage: %{mode: :delta, scope: :turn, identity: :atom_delta}
      })

    assert %Usage{mode: :absolute, scope: :thread, identity: "string-absolute"} = string_absolute.usage
    assert %Usage{mode: :delta, scope: :turn, identity: :atom_delta} = atom_delta.usage

    invalid_timestamp =
      AgentServer.normalize_event(:codex, %{
        type: :notification,
        timestamp: "not-a-date",
        error: %{kind: 123, message: "fallback kind"}
      })

    assert %DateTime{} = invalid_timestamp.timestamp
    assert %Error{kind: :provider} = invalid_timestamp.error
  end

  test "typed error normalization covers timeout、exit、cancel、failure 和 fallback" do
    existing = Error.new(:provider, "existing")
    assert AgentServer.normalize_error(existing, :startup) == existing

    assert %Error{kind: :timeout, code: :response_timeout, retryable?: true} =
             AgentServer.normalize_error(:response_timeout)

    assert %Error{kind: :process_exit, code: 17, retryable?: true} = AgentServer.normalize_error({:port_exit, 17})

    assert %Error{kind: :cancelled, code: :turn_cancelled, retryable?: true} =
             AgentServer.normalize_error({:turn_cancelled, :cancelled})

    assert %Error{kind: :provider, code: :turn_failed, retryable?: true} =
             AgentServer.normalize_error({:turn_failed, :failed})

    assert %Error{kind: :startup, code: :workspace_prepare_failed, retryable?: true} =
             AgentServer.normalize_error({:workspace_prepare_failed, "worker-a", 75, "secret output"})

    assert %Error{kind: :startup, message: "plain startup"} =
             AgentServer.normalize_error("plain startup", :startup)
  end

  test "backend 配置默认 Codex，支持 Claude Code，并拒绝非法值" do
    assert Config.settings!().agent.backend == "codex"
    assert Config.agent_backend() == :codex
    assert AgentServer.backend_module(:codex) == SymphonyElixir.Codex.AppServer

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude_code")

    assert Config.settings!().agent.backend == "claude_code"
    assert Config.agent_backend() == :claude_code
    assert Config.agent_backend_module() == SymphonyElixir.ClaudeCodeBackend

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "unknown")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.backend"
  end

  test "Claude Code command 默认 claude，并拒绝空或纯空白命令" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "claude_code" => %{}
             })

    assert settings.claude_code.command == "claude"

    Enum.each(["", "   \t"], fn command ->
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude_code",
        claude_code_command: command
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "claude_code.command"
      assert message =~ "can't be blank"
    end)
  end

  test "Claude Code 独立配置和有效 stall timeout 可 reload" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude_code",
      claude_code_command: "env CLAUDE_PROFILE=test claude",
      claude_code_model: "sonnet",
      claude_code_permission_mode: "acceptEdits",
      claude_code_allowed_tools: ["Read", "Edit"],
      claude_code_disallowed_tools: ["Bash"],
      claude_code_mcp_config: %{"mcpServers" => %{}},
      claude_code_include_partial_messages: false,
      claude_code_turn_timeout_ms: 12_000,
      claude_code_stall_timeout_ms: 4_000
    )

    settings = Config.settings!()
    assert settings.claude_code.command == "env CLAUDE_PROFILE=test claude"
    assert settings.claude_code.model == "sonnet"
    assert settings.claude_code.permission_mode == "acceptEdits"
    assert settings.claude_code.allowed_tools == ["Read", "Edit"]
    assert settings.claude_code.disallowed_tools == ["Bash"]
    assert settings.claude_code.mcp_config == %{"mcpServers" => %{}}
    refute settings.claude_code.include_partial_messages
    assert Config.agent_stall_timeout_ms() == 4_000

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude_code",
      claude_code_permission_mode: "auto"
    )

    assert Config.settings!().claude_code.permission_mode == "auto"

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex", codex_stall_timeout_ms: 7_000)
    assert Config.agent_stall_timeout_ms() == 7_000
  end

  test "AgentRunner 通过注入 backend 完成 start、多轮 session handoff、统一事件和 stop" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-agent-server-runner-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 2)

    issue = %Issue{
      id: "agent-contract-1",
      identifier: "AGENT-1",
      title: "backend handoff",
      description: "test",
      state: "In Progress",
      url: "https://example.test/AGENT-1",
      labels: [],
      dispatchable: true
    }

    {:ok, fetch_count} = Agent.start_link(fn -> 0 end)

    issue_state_fetcher = fn [_issue_id] ->
      count = Agent.get_and_update(fetch_count, &{&1, &1 + 1})
      state = if count == 0, do: "In Progress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    assert :ok =
             AgentRunner.run(issue, self(),
               backend_module: FakeBackend,
               backend_start_opts: [owner: self()],
               issue_state_fetcher: issue_state_fetcher,
               max_turns: 2
             )

    assert_received {:fake_backend, :started, workspace, opts}
    assert String.ends_with?(workspace, "/AGENT-1")
    assert opts[:owner] == self()
    assert_received {:fake_backend, :turn, 1, "initial-session", _prompt}
    assert_received {:fake_backend, :turn, 2, "provider-session-1", _prompt}
    assert_received {:fake_backend, :stopped, 2, "provider-session-2"}

    assert_received {:agent_worker_update, "agent-contract-1", %Event{backend: :claude_code, session_id: "provider-session-1"}}

    refute_received {:codex_worker_update, "agent-contract-1", _event}
  end

  test "AgentRunner 对 startup/turn failure 发送 typed event，异常路径 guaranteed stop 且错误文本脱敏" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-failure-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 1)

    issue = %Issue{
      id: "agent-failure-1",
      identifier: "AGENT-FAIL-1",
      title: "backend failure",
      description: "test",
      state: "In Progress",
      url: "https://example.test/AGENT-FAIL-1",
      labels: [],
      dispatchable: true
    }

    startup_error =
      assert_raise RuntimeError, fn ->
        AgentRunner.run(issue, self(),
          backend_module: RunnerFailureBackend,
          backend_start_opts: [owner: self(), failure_mode: :startup],
          max_turns: 1
        )
      end

    assert startup_error.message =~ "kind=startup code=startup_failed"
    refute startup_error.message =~ "backend startup failed"
    refute startup_error.message =~ "startup-raw-secret"

    assert_received {:agent_worker_update, "agent-failure-1",
                     %Event{
                       type: :startup_failed,
                       error: %Error{kind: :startup, code: :startup_failed}
                     }}

    turn_error =
      assert_raise RuntimeError, fn ->
        AgentRunner.run(issue, self(),
          backend_module: RunnerFailureBackend,
          backend_start_opts: [owner: self(), failure_mode: :turn_error],
          max_turns: 1
        )
      end

    assert turn_error.message =~ "kind=provider code=turn_failed"
    refute turn_error.message =~ "backend turn failed"
    refute turn_error.message =~ "turn-raw-secret"
    assert_received {:runner_failure_backend, :stopped, :turn_error}

    assert_received {:agent_worker_update, "agent-failure-1",
                     %Event{
                       type: :turn_failed,
                       error: %Error{kind: :provider, code: :turn_failed}
                     }}

    raised =
      assert_raise RuntimeError, fn ->
        AgentRunner.run(issue, self(),
          backend_module: RunnerFailureBackend,
          backend_start_opts: [owner: self(), failure_mode: :raise],
          max_turns: 1
        )
      end

    assert_received {:runner_failure_backend, :stopped, :raise}
    refute raised.message =~ "raw-secret-value"
  end

  test "AgentRunner 在 tracker 刷新抛错时使用本轮更新后 session 执行 guaranteed stop" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-latest-session-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 2)

    issue = %Issue{
      id: "agent-latest-session",
      identifier: "AGENT-LATEST",
      title: "latest session cleanup",
      description: "test",
      state: "In Progress",
      url: "https://example.test/AGENT-LATEST",
      labels: [],
      dispatchable: true
    }

    issue_state_fetcher = fn [_issue_id] -> raise "tracker refresh exploded" end

    assert_raise RuntimeError, fn ->
      AgentRunner.run(issue, self(),
        backend_module: FakeBackend,
        backend_start_opts: [owner: self()],
        issue_state_fetcher: issue_state_fetcher,
        max_turns: 2
      )
    end

    assert_received {:fake_backend, :turn, 1, "initial-session", _prompt}
    assert_received {:fake_backend, :stopped, 1, "provider-session-1"}
  end
end
