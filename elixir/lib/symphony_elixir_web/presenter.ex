defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      raw_events: raw_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    recent_events = recent_events_payload(entry)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      },
      execution: execution_payload(entry, recent_events),
      recent_events: recent_events
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running) do
    recent_events = recent_events_payload(running)

    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      },
      execution: execution_payload(running, recent_events)
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    entry
    |> codex_updates()
    |> Enum.map(&codex_update_payload/1)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp raw_events_payload(nil), do: []

  defp raw_events_payload(entry) do
    case Map.get(entry, :raw_codex_updates) do
      updates when is_list(updates) ->
        Enum.map(updates, &json_safe_value/1)

      _ ->
        []
    end
  end

  defp codex_updates(entry) do
    case Map.get(entry, :codex_updates) do
      updates when is_list(updates) and updates != [] ->
        updates

      _ ->
        last_codex_update(entry)
    end
  end

  defp last_codex_update(entry) do
    case Map.get(entry, :last_codex_timestamp) do
      nil ->
        []

      timestamp ->
        [
          %{
            event: Map.get(entry, :last_codex_event),
            message: Map.get(entry, :last_codex_message),
            timestamp: timestamp
          }
        ]
    end
  end

  defp codex_update_payload(update) do
    normalized_update = normalize_codex_update(update)

    %{
      at: iso8601(normalized_update.timestamp),
      event: normalized_update.event,
      message: normalized_update.display_message || summarize_message(normalized_update)
    }
  end

  defp normalize_codex_update(update) when is_map(update) do
    %{
      event: Map.get(update, :event) || Map.get(update, "event"),
      message: Map.get(update, :message) || Map.get(update, "message"),
      timestamp: Map.get(update, :timestamp) || Map.get(update, "timestamp"),
      display_message: Map.get(update, :display_message) || Map.get(update, "display_message")
    }
  end

  defp normalize_codex_update(update) do
    %{event: nil, message: update, timestamp: nil, display_message: nil}
  end

  defp execution_payload(entry, recent_events) do
    event_text = execution_event_text(entry, recent_events)
    session_id = Map.get(entry, :session_id)
    workspace_path = Map.get(entry, :workspace_path)
    has_session? = present?(session_id)
    has_workspace? = present?(workspace_path)
    workspace_ready? = has_workspace? or has_session?

    has_blocker? =
      contains_any?(event_text, [
        "approval requested",
        "approval required",
        "blocked",
        "input required",
        "mcp elicitation",
        "requires approval",
        "requires operator input",
        "waiting for user input"
      ])

    has_turn_completed? = contains_any?(event_text, ["turn completed"])
    has_work_activity? = contains_any?(event_text, ["command", "tool", "file change", "diff", "patch"])
    has_plan_activity? = contains_any?(event_text, ["inspect", "plan", "reasoning"])

    steps = [
      execution_step("Dispatched to worker", "done", "Agent task is running."),
      execution_step(
        "Workspace prepared",
        if(workspace_ready?, do: "done", else: "pending"),
        workspace_step_detail(workspace_path, has_workspace?, has_session?)
      ),
      execution_step(
        "Codex session started",
        if(has_session?, do: "done", else: "active"),
        session_id || "Waiting for Codex to start."
      ),
      execution_step(
        "Plan and inspect",
        plan_step_status(has_session?, has_plan_activity?, has_work_activity?, has_turn_completed?),
        plan_step_detail(has_work_activity?, has_turn_completed?)
      ),
      execution_step(
        "Run commands or edit files",
        work_step_status(has_work_activity?, has_turn_completed?),
        work_step_detail(has_work_activity?, has_turn_completed?)
      ),
      execution_step(
        "Finish turn",
        if(has_turn_completed?, do: "done", else: "pending"),
        if(has_turn_completed?, do: "Codex reported a completed turn.", else: "No completed turn reported yet.")
      )
    ]

    current_stage =
      current_stage(
        has_session?,
        has_blocker?,
        has_turn_completed?,
        has_work_activity?,
        has_plan_activity?
      )

    %{
      current_stage: current_stage,
      completed_count: Enum.count(steps, &(&1.status == "done")),
      pending_count: Enum.count(steps, &(&1.status == "pending")),
      steps: steps
    }
  end

  defp execution_event_text(entry, recent_events) do
    [
      Map.get(entry, :state),
      Map.get(entry, :last_codex_event),
      summarize_message(Map.get(entry, :last_codex_message))
      | Enum.flat_map(recent_events, fn event -> [event.event, event.message] end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp execution_step(label, status, detail), do: %{label: label, status: status, detail: detail}

  defp workspace_step_detail(workspace_path, true, _has_session?), do: workspace_path
  defp workspace_step_detail(_workspace_path, _has_workspace?, true), do: "Workspace path was not reported."
  defp workspace_step_detail(_workspace_path, _has_workspace?, _has_session?), do: "Waiting for worker runtime info."

  defp plan_step_status(false, _has_plan_activity?, _has_work_activity?, _has_turn_completed?), do: "pending"
  defp plan_step_status(_has_session?, _has_plan_activity?, true, _has_turn_completed?), do: "done"
  defp plan_step_status(_has_session?, _has_plan_activity?, _has_work_activity?, true), do: "done"
  defp plan_step_status(_has_session?, true, _has_work_activity?, _has_turn_completed?), do: "done"
  defp plan_step_status(_has_session?, _has_plan_activity?, _has_work_activity?, _has_turn_completed?), do: "active"

  defp plan_step_detail(true, _has_turn_completed?), do: "Planning activity already led to command, tool, or diff activity."
  defp plan_step_detail(_has_work_activity?, true), do: "Planning activity reached a completed turn."
  defp plan_step_detail(_has_work_activity?, _has_turn_completed?), do: "Agent is inspecting or planning next steps."

  defp work_step_status(_has_work_activity?, true), do: "done"
  defp work_step_status(true, _has_turn_completed?), do: "active"
  defp work_step_status(_has_work_activity?, _has_turn_completed?), do: "pending"

  defp work_step_detail(_has_work_activity?, true), do: "Command or edit activity reached the end of the turn."
  defp work_step_detail(true, _has_turn_completed?), do: "Latest activity includes commands, tools, file changes, or diffs."
  defp work_step_detail(_has_work_activity?, _has_turn_completed?), do: "Waiting for command, tool, or diff activity."

  defp current_stage(_has_session?, true, _has_turn_completed?, _has_work_activity?, _has_plan_activity?),
    do: "Waiting for input"

  defp current_stage(_has_session?, _has_blocker?, true, _has_work_activity?, _has_plan_activity?),
    do: "Turn completed"

  defp current_stage(_has_session?, _has_blocker?, _has_turn_completed?, true, _has_plan_activity?),
    do: "Running commands or edits"

  defp current_stage(_has_session?, _has_blocker?, _has_turn_completed?, _has_work_activity?, true),
    do: "Planning / inspecting"

  defp current_stage(true, _has_blocker?, _has_turn_completed?, _has_work_activity?, _has_plan_activity?),
    do: "Agent working"

  defp current_stage(_has_session?, _has_blocker?, _has_turn_completed?, _has_work_activity?, _has_plan_activity?),
    do: "Dispatching"

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp json_safe_value(%DateTime{} = datetime), do: iso8601(datetime)

  defp json_safe_value(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  defp json_safe_value(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {json_safe_key(key), json_safe_value(value)} end)
    |> Map.new()
  end

  defp json_safe_value(list) when is_list(list), do: Enum.map(list, &json_safe_value/1)
  defp json_safe_value(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe_value(value) when is_atom(value), do: json_safe_atom(value)
  defp json_safe_value(value) when is_binary(value) or is_integer(value) or is_float(value), do: value
  defp json_safe_value(value), do: inspect(value)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: to_string(key)

  defp json_safe_atom(nil), do: nil
  defp json_safe_atom(true), do: true
  defp json_safe_atom(false), do: false
  defp json_safe_atom(value), do: Atom.to_string(value)

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
