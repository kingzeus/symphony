defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec report_blocked_issue(Issue.t(), map()) :: {:ok, Issue.t()} | {:error, term()}
  def report_blocked_issue(%Issue{} = issue, report) when is_map(report) do
    case Map.get(report, :target_state) do
      target_state when is_binary(target_state) and target_state != "" ->
        updated_issue = %{issue | state: target_state, updated_at: DateTime.utc_now()}

        updated_issues =
          Enum.map(issue_entries(), fn
            %Issue{id: issue_id} when issue_id == issue.id -> updated_issue
            other -> other
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_issues, updated_issues)
        notify_blocked_report(issue, report)
        {:ok, updated_issue}

      _ ->
        {:error, :missing_tracker_waiting_state}
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp notify_blocked_report(issue, report) do
    case Application.get_env(:symphony_elixir, :memory_tracker_report_recipient) do
      pid when is_pid(pid) -> send(pid, {:memory_tracker_blocked_report, issue, report})
      _ -> :ok
    end
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
