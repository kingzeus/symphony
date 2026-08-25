defmodule SymphonyElixir.AgentEventOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentServer.{Approval, Error, Event, Usage}
  alias SymphonyElixirWeb.ObservabilityPubSub
  alias SymphonyElixirWeb.Presenter

  test "absolute/thread 与 delta/turn 正确聚合，usage identity 去重且 cache 字段保留" do
    {pid, orchestrator_name, issue_id, _ref} =
      start_orchestrator_with_running_issue(:AgentUsage, :claude_code)

    now = DateTime.utc_now()

    events = [
      Event.new(:codex, :notification,
        timestamp: now,
        usage: Usage.absolute(:thread, 10, 5, {:codex, 1}, total_tokens: 15, cache_read_input_tokens: 2)
      ),
      Event.new(:codex, :notification,
        timestamp: DateTime.add(now, 1, :second),
        usage: Usage.absolute(:thread, 12, 6, {:codex, 2}, total_tokens: 18, cache_read_input_tokens: 4)
      ),
      Event.new(:codex, :notification,
        timestamp: DateTime.add(now, 2, :second),
        usage: Usage.absolute(:thread, 12, 6, {:codex, 2}, total_tokens: 18, cache_read_input_tokens: 4)
      ),
      Event.new(:claude_code, :turn_completed,
        timestamp: DateTime.add(now, 3, :second),
        usage:
          Usage.delta(:turn, 4, 2, {:claude, 1},
            total_tokens: 6,
            cache_read_input_tokens: 3,
            cache_creation_input_tokens: 1
          )
      ),
      Event.new(:claude_code, :turn_completed,
        timestamp: DateTime.add(now, 4, :second),
        usage:
          Usage.delta(:turn, 4, 2, {:claude, 1},
            total_tokens: 6,
            cache_read_input_tokens: 3,
            cache_creation_input_tokens: 1
          )
      ),
      Event.new(:claude_code, :turn_completed,
        timestamp: DateTime.add(now, 5, :second),
        usage:
          Usage.delta(:turn, 1, 1, {:claude, 2},
            total_tokens: 2,
            cache_read_input_tokens: 1,
            cache_creation_input_tokens: 2
          )
      )
    ]

    Enum.each(events, &send(pid, {:agent_worker_update, issue_id, &1}))

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert entry.backend == :claude_code
    assert entry.agent_input_tokens == 17
    assert entry.agent_output_tokens == 9
    assert entry.agent_total_tokens == 26
    assert entry.agent_cache_read_input_tokens == 8
    assert entry.agent_cache_creation_input_tokens == 3
    assert entry.codex_input_tokens == 17
    assert entry.codex_output_tokens == 9
    assert entry.codex_total_tokens == 26
    assert MapSet.size(entry.agent_usage_identities) == 2

    assert snapshot.agent_totals.input_tokens == 17
    assert snapshot.agent_totals.output_tokens == 9
    assert snapshot.agent_totals.total_tokens == 26
    assert snapshot.agent_totals.cache_read_input_tokens == 8
    assert snapshot.agent_totals.cache_creation_input_tokens == 3
    assert snapshot.codex_totals == snapshot.agent_totals

    payload = Presenter.state_payload(orchestrator_name, 1_000)
    assert payload.agent_totals == payload.codex_totals
    assert [presented] = payload.running
    assert presented.backend == :claude_code
    assert presented.tokens.total_tokens == 26
    assert presented.codex_total_tokens == 26

    assert {:ok, issue_payload} = Presenter.issue_payload("AGENT-AgentUsage", orchestrator_name, 1_000)
    assert issue_payload.logs == %{agent_session_logs: [], codex_session_logs: []}
    assert raw_events = issue_payload.raw_events
    assert get_in(List.last(raw_events), ["usage", "mode"]) == "delta"
    refute inspect(raw_events) =~ "__struct__"
  end

  test "typed approval/input error 持久回写 waiting state 且不进入 retry" do
    {pid, _name, issue_id, ref} = start_orchestrator_with_running_issue(:AgentBlocked)
    Application.put_env(:symphony_elixir, :memory_tracker_report_recipient, self())

    error =
      Error.new(:approval_required, "Claude Code requires tool approval",
        code: :permission_denied,
        blocked?: true,
        retryable?: false
      )

    approval = Approval.new(:tool, :required, request_id: "request-1")

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :approval_required, error: error, approval: approval)}
    )

    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :approval_required}})
    Process.sleep(30)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert_receive {:memory_tracker_blocked_report, %Issue{id: ^issue_id}, report}
    assert report.target_state == "Human Review"
    assert report.message == "Claude Code requires tool approval"
    assert report.typed_error == error
    assert report.approval == approval

    assert [%Issue{id: ^issue_id, state: "Human Review"}] =
             Application.get_env(:symphony_elixir, :memory_tracker_issues)
  end

  test "typed transient provider error 进入 retry" do
    {pid, _name, issue_id, ref} = start_orchestrator_with_running_issue(:AgentRetry)

    error =
      Error.new(:provider, "rate limited", code: "rate_limit", retryable?: true, blocked?: false)

    send(pid, {:agent_worker_update, issue_id, Event.new(:claude_code, :turn_failed, error: error)})
    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :provider_error}})
    Process.sleep(30)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 1, error: "rate limited"} = state.retry_attempts[issue_id]
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "turn_count 按 turn_id 去重而不是按 session_id 去重" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:TurnIdentity)
    now = DateTime.utc_now()

    send(
      pid,
      {:agent_worker_update, issue_id,
       Event.new(:claude_code, :session_started,
         session_id: "claude-session",
         turn_id: "turn-1",
         timestamp: now
       )}
    )

    send(
      pid,
      {:agent_worker_update, issue_id,
       Event.new(:claude_code, :session_started,
         session_id: "claude-session",
         turn_id: "turn-2",
         timestamp: DateTime.add(now, 1, :second)
       )}
    )

    send(
      pid,
      {:agent_worker_update, issue_id,
       Event.new(:claude_code, :session_started,
         session_id: "claude-session",
         turn_id: "turn-2",
         timestamp: DateTime.add(now, 2, :second)
       )}
    )

    assert %{running: [%{turn_count: 2}]} = GenServer.call(pid, :snapshot)
  end

  test "string-key session_started 使用 normalized type 累计 turn 并保留兼容 event" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:StringTurnIdentity)
    now = DateTime.utc_now()

    Enum.each(["turn-string-1", "turn-string-2", "turn-string-2"], fn turn_id ->
      send(
        pid,
        {:agent_worker_update, issue_id,
         %{
           "event" => "session_started",
           "timestamp" => now,
           "session_id" => "session-string",
           "thread_id" => "thread-string",
           "turn_id" => turn_id,
           "process_id" => "4321"
         }}
      )
    end)

    assert %{running: [entry]} = GenServer.call(pid, :snapshot)
    running_entry = :sys.get_state(pid).running[issue_id]
    assert entry.turn_count == 2
    assert running_entry.last_turn_id == "turn-string-2"
    assert entry.session_id == "session-string"
    assert entry.agent_process_id == "4321"
    assert entry.last_agent_event == :session_started
    assert entry.last_codex_event == "session_started"
    assert Enum.all?(entry.raw_agent_updates, &(&1.event == "session_started"))
  end

  test "普通 progress 不会清除尚未解决的 error 和 approval" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:StickyApproval)

    error =
      Error.new(:approval_required, "Claude Code requires tool approval",
        code: :permission_denied,
        blocked?: true,
        retryable?: false
      )

    approval = Approval.new(:tool, :required, request_id: "request-sticky")

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :approval_required, error: error, approval: approval)}
    )

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :notification, payload: %{"type" => "assistant"})}
    )

    assert %{running: [entry]} = GenServer.call(pid, :snapshot)
    assert entry.last_agent_error == error
    assert entry.last_agent_approval == approval
  end

  test "approval_resolved 清除已解决的 blocked error 和 approval" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:ResolvedApproval)

    error =
      Error.new(:approval_required, "Claude Code requires tool approval",
        code: :permission_denied,
        blocked?: true,
        retryable?: false
      )

    approval = Approval.new(:tool, :required, request_id: "request-resolved")

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :approval_required, error: error, approval: approval)}
    )

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :approval_resolved, approval: Approval.new(:tool, :resolved, request_id: "request-resolved", decision: :approved))}
    )

    assert %{running: [entry]} = GenServer.call(pid, :snapshot)
    assert entry.last_agent_error == nil
    assert entry.last_agent_approval == nil
  end

  test "legacy update 使用 running entry 冻结的 backend" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:FrozenBackend)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude_code",
      poll_interval_ms: 60_000
    )

    send(
      pid,
      {:agent_worker_update, issue_id, %{event: :notification, payload: %{"method" => "item/updated"}, timestamp: DateTime.utc_now()}}
    )

    assert %{running: [%{backend: :codex}]} = GenServer.call(pid, :snapshot)
  end

  test "stall reconcile 使用 running entry 冻结的 timeout" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:FrozenStallTimeout)
    stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      update_in(state.running[issue_id], fn entry ->
        Map.merge(entry, %{
          pid: worker_pid,
          stall_timeout_ms: 10_000,
          last_agent_timestamp: stale_at,
          started_at: stale_at
        })
      end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000,
      poll_interval_ms: 60_000
    )

    send(pid, :run_poll_cycle)
    Process.sleep(30)

    state = :sys.get_state(pid)
    assert Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "absolute usage 不累积 identity，delta usage identity 在整个运行生命周期去重" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:BoundedUsageIdentity)

    Enum.each(1..600, fn index ->
      send(
        pid,
        {:agent_worker_update, issue_id, Event.new(:claude_code, :turn_completed, usage: Usage.delta(:turn, 1, 1, {:delta, index}))}
      )
    end)

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:codex, :notification, usage: Usage.absolute(:thread, 700, 700, {:absolute, 1}))}
    )

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:codex, :notification, usage: Usage.absolute(:thread, 701, 701, {:absolute, 2}))}
    )

    assert %{running: [entry]} = GenServer.call(pid, :snapshot)
    assert entry.agent_input_tokens == 1_301
    assert entry.agent_output_tokens == 1_301
    assert MapSet.size(entry.agent_usage_identities) == 600
    refute MapSet.member?(entry.agent_usage_identities, {:absolute, 1})
    refute MapSet.member?(entry.agent_usage_identities, {:absolute, 2})

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :turn_completed, usage: Usage.delta(:turn, 1, 1, {:delta, 1}))}
    )

    assert %{running: [%{agent_input_tokens: 1_301}]} = GenServer.call(pid, :snapshot)
  end

  test "progress 与 partial streaming 只更新活动状态，terminal 事件才广播 dashboard" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:PartialProgress)
    assert :ok = ObservabilityPubSub.subscribe()

    Process.sleep(50)
    _snapshot = GenServer.call(pid, :snapshot)
    drain_observability_updates()

    progress_at = DateTime.utc_now()

    send(
      pid,
      {:agent_worker_update, issue_id,
       Event.new(:claude_code, :progress,
         timestamp: progress_at,
         payload: %{"type" => "progress", "message" => "working"}
       )}
    )

    assert %{running: [%{last_agent_timestamp: ^progress_at, last_agent_event: :progress}]} =
             GenServer.call(pid, :snapshot)

    refute_receive :observability_updated, 50

    streaming_at = DateTime.add(progress_at, 1, :second)

    send(
      pid,
      {:agent_worker_update, issue_id,
       Event.new(:claude_code, :notification,
         timestamp: streaming_at,
         payload: streaming_payload("progress-message", "partial")
       )}
    )

    assert %{running: [%{last_agent_timestamp: ^streaming_at, last_agent_event: :notification}]} =
             GenServer.call(pid, :snapshot)

    refute_receive :observability_updated, 50

    send(pid, {:agent_worker_update, issue_id, Event.new(:claude_code, :turn_completed)})
    _snapshot = GenServer.call(pid, :snapshot)
    assert_receive :observability_updated, 200
  end

  test "streaming summary 单流限制为 65536 bytes 且保持 UTF-8 合法" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:BoundedStreaming)
    chunk = String.duplicate("好", 10_000)

    Enum.each(1..3, fn _index ->
      send(
        pid,
        {:agent_worker_update, issue_id, Event.new(:claude_code, :notification, payload: streaming_payload("bounded-message", chunk))}
      )
    end)

    assert %{running: [%{last_agent_message: %{stream_merge: stream_merge}}]} =
             GenServer.call(pid, :snapshot)

    assert byte_size(stream_merge.delta) <= 65_536
    assert String.valid?(stream_merge.delta)
    assert stream_merge.truncated == true
  end

  test "orchestrator 先协作取消并传递明确 reason，超时后强制终止不协作 worker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000,
      codex_stall_timeout_ms: 10
    )

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    orchestrator_name = Module.concat(__MODULE__, :CooperativeCancellation)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, task_supervisor: task_supervisor)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(task_supervisor), do: Process.exit(task_supervisor, :normal)
    end)

    cooperative_worker = fn label, issue_id, token_count ->
      {:ok, worker_pid} =
        Task.Supervisor.start_child(task_supervisor, fn ->
          try do
            receive do
              {:agent_cancel, reason} ->
                send(
                  pid,
                  {:agent_worker_update, issue_id,
                   Event.new(:claude_code, :turn_cancelled,
                     session_id: "session-#{label}",
                     usage:
                       Usage.delta(
                         :turn,
                         token_count,
                         token_count,
                         {:cancelled, label},
                         total_tokens: token_count * 2
                       )
                   )}
                )

                send(parent, {:agent_cancelled, label, reason})
            end
          after
            send(parent, {:agent_cleanup, label})
          end
        end)

      worker_pid
    end

    stall_pid = cooperative_worker.(:stall, "cancel-stall", 1)
    blocked_pid = cooperative_worker.(:blocked, "cancel-blocked", 2)
    ordinary_pid = cooperative_worker.(:ordinary, "cancel-ordinary", 3)

    {:ok, slow_cleanup_pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        try do
          receive do
            {:agent_cancel, reason} ->
              send(
                pid,
                {:agent_worker_update, "cancel-slow-cleanup", Event.new(:claude_code, :turn_cancelled, error: Error.new(:cancelled, "cancelled", code: reason))}
              )

              send(parent, {:agent_cancelled, :slow_cleanup, reason})
          end
        after
          Process.sleep(1_800)
          send(parent, {:agent_cleanup, :slow_cleanup})
        end
      end)

    {:ok, uncooperative_pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        receive do
          :unrelated -> :ok
        end
      end)

    stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
    fresh_at = DateTime.utc_now()

    issues = [
      cancellation_issue("cancel-stall", "CANCEL-STALL", "In Progress"),
      cancellation_issue("cancel-blocked", "CANCEL-BLOCKED", "In Progress"),
      cancellation_issue("cancel-ordinary", "CANCEL-ORDINARY", "Closed"),
      cancellation_issue("cancel-slow-cleanup", "CANCEL-SLOW-CLEANUP", "Closed"),
      cancellation_issue("cancel-uncooperative", "CANCEL-UNCOOPERATIVE", "Closed")
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      running = %{
        "cancel-stall" => cancellation_entry(Enum.at(issues, 0), stall_pid, Process.monitor(stall_pid), stale_at),
        "cancel-blocked" =>
          cancellation_entry(Enum.at(issues, 1), blocked_pid, Process.monitor(blocked_pid), stale_at)
          |> Map.put(
            :last_agent_error,
            Error.new(:approval_required, "approval required", blocked?: true)
          ),
        "cancel-ordinary" => cancellation_entry(Enum.at(issues, 2), ordinary_pid, Process.monitor(ordinary_pid), fresh_at),
        "cancel-slow-cleanup" =>
          cancellation_entry(
            Enum.at(issues, 3),
            slow_cleanup_pid,
            Process.monitor(slow_cleanup_pid),
            fresh_at
          ),
        "cancel-uncooperative" =>
          cancellation_entry(
            Enum.at(issues, 4),
            uncooperative_pid,
            Process.monitor(uncooperative_pid),
            fresh_at
          )
      }

      %{
        state
        | running: running,
          claimed: MapSet.new(Map.keys(running)),
          tick_timer_ref: nil,
          tick_token: nil,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)
    snapshot = GenServer.call(pid, :snapshot, 5_000)

    assert_receive {:agent_cancelled, :stall, :stall_timeout}, 1_000
    assert_receive {:agent_cleanup, :stall}, 1_000
    assert_receive {:agent_cancelled, :blocked, :blocked}, 1_000
    assert_receive {:agent_cleanup, :blocked}, 1_000
    assert_receive {:agent_cancelled, :ordinary, :orchestrator_stop}, 1_000
    assert_receive {:agent_cleanup, :ordinary}, 1_000
    assert_receive {:agent_cancelled, :slow_cleanup, :orchestrator_stop}, 3_000
    assert_receive {:agent_cleanup, :slow_cleanup}, 3_000

    assert snapshot.agent_totals.input_tokens == 6
    assert snapshot.agent_totals.output_tokens == 6
    assert snapshot.agent_totals.total_tokens == 12

    refute Process.alive?(uncooperative_pid)

    monitored_pids =
      pid
      |> Process.info(:monitors)
      |> elem(1)
      |> Enum.flat_map(fn
        {:process, monitored_pid} -> [monitored_pid]
        _other -> []
      end)

    refute stall_pid in monitored_pids
    refute blocked_pid in monitored_pids
    refute ordinary_pid in monitored_pids
    refute slow_cleanup_pid in monitored_pids
    refute uncooperative_pid in monitored_pids
  end

  test "orchestrator 对已确认取消的故障 worker 保留不可续期 cleanup 硬上限" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000
    )

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    orchestrator_name = Module.concat(__MODULE__, :CancellationCleanupDeadline)

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        task_supervisor: task_supervisor,
        agent_cancel_cleanup_timeout_ms: 50
      )

    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(task_supervisor), do: Process.exit(task_supervisor, :normal)
    end)

    issue = cancellation_issue("cancel-ack-hang", "CANCEL-ACK-HANG", "Closed")

    {:ok, worker_pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        receive do
          {:agent_cancel, reason} ->
            send(
              pid,
              {:agent_worker_update, issue.id, Event.new(:claude_code, :turn_cancelled, error: Error.new(:cancelled, "cancelled", code: reason))}
            )

            send(parent, {:cancel_acknowledged, reason})

            receive do
              :never -> :ok
            end
        end
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    timestamp = DateTime.utc_now()

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      running_entry =
        issue
        |> cancellation_entry(worker_pid, Process.monitor(worker_pid), timestamp)
        |> Map.put(:backend, :claude_code)

      %{
        state
        | running: %{issue.id => running_entry},
          claimed: MapSet.new([issue.id]),
          tick_timer_ref: nil,
          tick_token: nil,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)
    snapshot = GenServer.call(pid, :snapshot, 2_000)

    assert_receive {:cancel_acknowledged, :orchestrator_stop}, 1_000
    refute Process.alive?(worker_pid)
    assert snapshot.running == []
  end

  test "orchestrator cleanup 硬上限不被持续 agent update 洪泛绕过" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000
    )

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    orchestrator_name = Module.concat(__MODULE__, :CancellationCleanupFloodDeadline)

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        task_supervisor: task_supervisor,
        agent_cancel_cleanup_timeout_ms: 50
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(task_supervisor), do: Process.exit(task_supervisor, :normal)
    end)

    issue = cancellation_issue("cancel-ack-flood", "CANCEL-ACK-FLOOD", "Closed")

    {:ok, worker_pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        receive do
          {:agent_cancel, reason} ->
            send(
              pid,
              {:agent_worker_update, issue.id, Event.new(:claude_code, :turn_cancelled, error: Error.new(:cancelled, "cancelled", code: reason))}
            )

            flood_update = Event.new(:claude_code, :progress, payload: %{phase: :cleanup})
            flood_agent_updates(pid, issue.id, flood_update)
        end
      end)

    worker_ref = Process.monitor(worker_pid)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    timestamp = DateTime.utc_now()

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      running_entry =
        issue
        |> cancellation_entry(worker_pid, Process.monitor(worker_pid), timestamp)
        |> Map.put(:backend, :claude_code)

      %{
        state
        | running: %{issue.id => running_entry},
          claimed: MapSet.new([issue.id]),
          tick_timer_ref: nil,
          tick_token: nil,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 1_000
  end

  test "raw event history 同时限制单条大小、总字节和条数" do
    {pid, _name, issue_id, _ref} = start_orchestrator_with_running_issue(:BoundedRawHistory)
    medium_payload = String.duplicate("m", 48_000)

    Enum.each(1..20, fn index ->
      send(
        pid,
        {:agent_worker_update, issue_id, Event.new(:claude_code, :notification, payload: %{"index" => index, "content" => medium_payload})}
      )
    end)

    send(
      pid,
      {:agent_worker_update, issue_id, Event.new(:claude_code, :notification, payload: %{"content" => String.duplicate("x", 100_000)})}
    )

    assert %{running: [%{raw_agent_updates: raw_updates}]} = GenServer.call(pid, :snapshot)
    assert length(raw_updates) <= 200
    assert Enum.all?(raw_updates, &(:erlang.external_size(&1) <= 65_536))
    assert Enum.sum(Enum.map(raw_updates, &:erlang.external_size/1)) <= 524_288
    assert List.last(raw_updates).truncated == true
  end

  defp start_orchestrator_with_running_issue(suffix, backend \\ :codex) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 60_000)
    issue_id = "agent-event-#{suffix}"
    orchestrator_name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    issue = %Issue{
      id: issue_id,
      identifier: "AGENT-#{suffix}",
      title: "Agent event",
      state: "In Progress",
      url: "https://example.test/#{suffix}",
      labels: [],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    initial_state = :sys.get_state(pid)
    ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      backend: backend,
      session_id: nil,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    {pid, orchestrator_name, issue_id, ref}
  end

  defp streaming_payload(message_id, delta) do
    %{
      "method" => "item/agentMessage/delta",
      "params" => %{"itemId" => message_id, "delta" => delta}
    }
  end

  defp drain_observability_updates do
    receive do
      :observability_updated -> drain_observability_updates()
    after
      0 -> :ok
    end
  end

  defp cancellation_issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Cancellation",
      state: state,
      url: "https://example.test/#{identifier}",
      labels: [],
      dispatchable: true
    }
  end

  defp cancellation_entry(issue, worker_pid, ref, timestamp) do
    %{
      pid: worker_pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      backend: :codex,
      session_id: nil,
      turn_count: 0,
      started_at: timestamp,
      last_agent_timestamp: timestamp,
      stall_timeout_ms: 10
    }
  end

  defp flood_agent_updates(orchestrator_pid, issue_id, update) do
    send(orchestrator_pid, {:agent_worker_update, issue_id, update})
    flood_agent_updates(orchestrator_pid, issue_id, update)
  end
end
