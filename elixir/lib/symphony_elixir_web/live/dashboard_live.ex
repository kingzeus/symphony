defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @backlog_display_limit 10
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:selected_issue_id, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:selected_issue_id, retained_selected_issue_id(payload, socket.assigns[:selected_issue_id]))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("select_session", %{"issue-id" => issue_id}, socket) do
    selected_issue_id =
      if running_issue_id?(socket.assigns.payload, issue_id) do
        issue_id
      end

    {:noreply, assign(socket, :selected_issue_id, selected_issue_id)}
  end

  def handle_event("clear_selected_session", _params, socket) do
    {:noreply, assign(socket, :selected_issue_id, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid issue-metric-grid">
          <article class="metric-card">
            <p class="metric-label">Backlog</p>
            <p class="metric-value numeric"><%= @payload.counts.backlog %></p>
            <p class="metric-detail">Tracker backlog and queued dispatch candidates.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Waiting</p>
            <p class="metric-value numeric"><%= @payload.counts.waiting %></p>
            <p class="metric-detail">Issues waiting for manual review or handoff.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>
        </section>

        <section class="runtime-metric-grid" aria-label="Runtime metrics">
          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card rate-limit-card">
            <p class="metric-label">Rate limits</p>
            <p class="metric-detail">Latest upstream rate-limit snapshot, when available.</p>
            <pre class="code-panel runtime-code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.running}
                    id={"running-session-#{running_entry_key(entry)}"}
                    class={running_row_class(entry, @selected_issue_id)}
                    phx-click="select_session"
                    phx-value-issue-id={running_entry_key(entry)}
                  >
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a
                          class="issue-link"
                          href={json_details_path(entry.issue_identifier)}
                          onclick="event.stopPropagation();"
                        >JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="event.stopPropagation(); navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <% selected_entry = selected_running_entry(@payload, @selected_issue_id) %>
            <%= if selected_entry do %>
              <section class="agent-detail-panel" id={"agent-detail-#{running_entry_key(selected_entry)}"}>
                <div class="agent-detail-header">
                  <div>
                    <p class="detail-kicker">Agent details</p>
                    <h3 class="agent-detail-title"><%= selected_entry.issue_identifier %></h3>
                    <p class="section-copy">
                      <%= selected_entry.execution.current_stage %> · <%= selected_entry.execution.completed_count %> completed / <%= selected_entry.execution.pending_count %> pending
                    </p>
                  </div>
                  <button type="button" class="subtle-button" phx-click="clear_selected_session">Close</button>
                </div>

                <div class="agent-stage-band">
                  <span class="detail-label">Current stage</span>
                  <strong><%= selected_entry.execution.current_stage %></strong>
                  <span class="muted agent-stage-update">
                    Last update:
                    <span class="agent-stage-message"><%= selected_entry.last_message || to_string(selected_entry.last_event || "n/a") %></span>
                  </span>
                </div>

                <div class="agent-detail-grid">
                  <div>
                    <span class="detail-label">State</span>
                    <strong><%= selected_entry.state %></strong>
                  </div>
                  <div>
                    <span class="detail-label">Runtime / turns</span>
                    <strong class="numeric"><%= format_runtime_and_turns(selected_entry.started_at, selected_entry.turn_count, @now) %></strong>
                  </div>
                  <div>
                    <span class="detail-label">Session</span>
                    <span class="mono"><%= selected_entry.session_id || "n/a" %></span>
                  </div>
                  <div>
                    <span class="detail-label">Worker</span>
                    <span><%= selected_entry.worker_host || "local" %></span>
                  </div>
                  <div class="detail-grid-wide">
                    <span class="detail-label">Workspace</span>
                    <span class="mono"><%= selected_entry.workspace_path || "n/a" %></span>
                  </div>
                </div>

                <div class="agent-detail-columns">
                  <div>
                    <h4 class="detail-subtitle">Execution checklist</h4>
                    <ol class="execution-steps">
                      <li :for={step <- selected_entry.execution.steps} class={execution_step_class(step.status)}>
                        <span class="step-state"><%= step_status_label(step.status) %></span>
                        <div class="step-copy">
                          <strong><%= step.label %></strong>
                          <span class="muted"><%= step.detail %></span>
                        </div>
                      </li>
                    </ol>
                  </div>

                  <div>
                    <h4 class="detail-subtitle">Recent Codex events</h4>
                    <%= if selected_entry.recent_events == [] do %>
                      <p class="empty-state empty-state-compact">No timestamped Codex events captured yet.</p>
                    <% else %>
                      <div class="event-list">
                        <div :for={event <- recent_events_for_display(selected_entry.recent_events)} class="event-row">
                          <span class="mono event-time"><%= event.at %></span>
                          <span class="event-message">
                            <%= event.message || to_string(event.event || "n/a") %>
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </section>
            <% else %>
              <p class="detail-hint">Click a running session to inspect live execution details.</p>
            <% end %>
          <% end %>
        </section>

        <div class="dashboard-section-grid">
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Backlog</h2>
                <p class="section-copy">Tracker backlog issues plus routable candidates waiting for dispatch.</p>
              </div>
            </div>

            <%= if @payload.backlog == [] do %>
              <p class="empty-state">No backlog issues.</p>
            <% else %>
              <%= if backlog_overflow_count(@payload.backlog) > 0 do %>
                <p class="list-summary">
                  Showing <%= backlog_display_limit() %> of <%= length(@payload.backlog) %>
                </p>
              <% end %>

              <div class="backlog-list">
                <article class="backlog-item" :for={entry <- backlog_for_display(@payload.backlog)}>
                  <div class="backlog-item-main">
                    <div class="backlog-title-line">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <span class={state_badge_class(entry.state || "Backlog")}>
                        <%= entry.state || "Backlog" %>
                      </span>
                    </div>
                    <span class="issue-title backlog-title"><%= entry.title || "Untitled issue" %></span>
                  </div>

                  <div class="backlog-meta">
                    <span class="numeric"><%= format_priority(entry.priority) %></span>
                    <span><%= entry.updated_at || entry.created_at || "n/a" %></span>
                    <span><%= format_labels(entry.labels) %></span>
                    <span><%= entry.assignee_id || "unassigned" %></span>
                    <a class="issue-link" href={json_details_path(entry.issue_identifier)}>JSON details</a>
                  </div>
                </article>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Retry queue</h2>
                <p class="section-copy">Issues waiting for the next retry window.</p>
              </div>
            </div>

            <%= if @payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={json_details_path(entry.issue_identifier)}>JSON details</a>
                        </div>
                      </td>
                      <td><%= entry.attempt %></td>
                      <td class="mono"><%= entry.due_at || "n/a" %></td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>
        </div>

        <div class="dashboard-section-grid">
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Waiting sessions</h2>
                <p class="section-copy">Issues in manual review or other configured waiting states.</p>
              </div>
            </div>

            <%= if @payload.waiting == [] do %>
              <p class="empty-state">No issues are waiting for manual review.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Updated at</th>
                      <th>Workspace</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.waiting}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={json_details_path(entry.issue_identifier)}>JSON details</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state || "Waiting")}>
                          <%= entry.state || "Waiting" %>
                        </span>
                      </td>
                      <td class="mono"><%= entry.updated_at || "n/a" %></td>
                      <td class="mono"><%= entry.workspace_path || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Blocked sessions</h2>
                <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
              </div>
            </div>

            <%= if @payload.blocked == [] do %>
              <p class="empty-state">No blocked sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
                      <th>Blocked at</th>
                      <th>Last update</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.blocked}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={json_details_path(entry.issue_identifier)}>JSON details</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state || "Blocked")}>
                          <%= entry.state || "Blocked" %>
                        </span>
                      </td>
                      <td>
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </td>
                      <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>
        </div>
      <% end %>
    </section>
    """
  end

  defp selected_running_entry(%{running: running}, selected_issue_id) when is_list(running) and is_binary(selected_issue_id) do
    Enum.find(running, &(running_entry_key(&1) == selected_issue_id))
  end

  defp selected_running_entry(_payload, _selected_issue_id), do: nil

  defp retained_selected_issue_id(payload, selected_issue_id) do
    if running_issue_id?(payload, selected_issue_id) do
      selected_issue_id
    end
  end

  defp running_issue_id?(%{running: running}, issue_id) when is_list(running) and is_binary(issue_id) do
    Enum.any?(running, &(running_entry_key(&1) == issue_id))
  end

  defp running_issue_id?(_payload, _issue_id), do: false

  defp running_entry_key(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, :issue_identifier) || "unknown"
  end

  defp running_row_class(entry, selected_issue_id) do
    base = "selectable-row"

    if running_entry_key(entry) == selected_issue_id do
      "#{base} selectable-row-selected"
    else
      base
    end
  end

  defp json_details_path(issue_identifier) do
    "/api/v1/#{URI.encode(to_string(issue_identifier))}?pretty=1"
  end

  defp recent_events_for_display(events) when is_list(events) do
    Enum.take(events, -8)
  end

  defp recent_events_for_display(_events), do: []

  defp backlog_display_limit, do: @backlog_display_limit

  defp backlog_for_display(backlog) when is_list(backlog) do
    Enum.take(backlog, @backlog_display_limit)
  end

  defp backlog_for_display(_backlog), do: []

  defp backlog_overflow_count(backlog) when is_list(backlog) do
    max(length(backlog) - @backlog_display_limit, 0)
  end

  defp backlog_overflow_count(_backlog), do: 0

  defp format_priority(priority) when is_integer(priority) and priority in 1..4, do: "P#{priority}"
  defp format_priority(_priority), do: "No priority"

  defp format_labels(labels) when is_list(labels) do
    label_names = Enum.filter(labels, &is_binary/1)

    case label_names do
      [] ->
        "none"

      _ ->
        visible_labels = Enum.take(label_names, 3) |> Enum.join(", ")
        extra_count = length(label_names) - 3

        if extra_count > 0 do
          "#{visible_labels} +#{extra_count}"
        else
          visible_labels
        end
    end
  end

  defp format_labels(_labels), do: "none"

  defp execution_step_class(status), do: "execution-step execution-step-#{status}"
  defp step_status_label("done"), do: "Done"
  defp step_status_label("active"), do: "Now"
  defp step_status_label(_status), do: "Next"

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
        onclick="event.stopPropagation();"
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    hours = div(whole_seconds, 3_600)
    mins = whole_seconds |> rem(3_600) |> div(60)
    secs = rem(whole_seconds, 60)

    if hours > 0 do
      "#{hours}h #{mins}m #{secs}s"
    else
      "#{mins}m #{secs}s"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "review", "waiting"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
