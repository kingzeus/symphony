defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the selected backend.
  """

  require Logger
  alias SymphonyElixir.{AgentServer, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case safely_run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        error = AgentServer.normalize_error(reason)
        error_text = safe_error_text(error)
        Logger.error("Agent run failed for #{issue_context(issue)}: #{error_text}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{error_text}"
    end
  end

  defp safely_run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
    run_on_worker_host(issue, agent_update_recipient, opts, worker_host)
  rescue
    _exception ->
      {:error,
       AgentServer.Error.new(:provider, "agent backend raised an exception",
         code: :backend_exception,
         retryable?: true
       )}
  catch
    _kind, _reason ->
      {:error,
       AgentServer.Error.new(:provider, "agent backend terminated unexpectedly",
         code: :backend_termination,
         retryable?: true
       )}
  end

  defp run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(agent_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue, backend, error_marker) do
    fn message ->
      event = AgentServer.normalize_event(backend, message)
      if not is_nil(event.error), do: Process.put(error_marker, true)
      send_agent_update(recipient, issue, event)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    backend_module = Keyword.get(opts, :backend_module, Config.agent_backend_module())
    backend = AgentServer.backend_name(backend_module)

    start_opts =
      opts
      |> Keyword.get(:backend_start_opts, [])
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:effort, Keyword.get(opts, :effort))

    case start_backend_session(backend_module, workspace, start_opts) do
      {:ok, session} ->
        final_session_marker = make_ref()

        loop = %{
          backend_module: backend_module,
          backend: backend,
          workspace: workspace,
          agent_update_recipient: agent_update_recipient,
          opts: opts,
          issue_state_fetcher: issue_state_fetcher,
          max_turns: max_turns,
          final_session_marker: final_session_marker
        }

        Process.put(final_session_marker, session)

        try do
          result = do_run_agent_turns(loop, session, issue, 1)
          Process.put(final_session_marker, final_session(result))
          normalize_turn_result(result)
        after
          final_session = Process.get(final_session_marker, session)
          Process.delete(final_session_marker)
          stop_session_safely(backend_module, final_session)
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason, :startup)
        send_agent_error(agent_update_recipient, issue, backend, :startup_failed, error)
        {:error, error}
    end
  end

  defp start_backend_session(backend_module, workspace, start_opts) do
    backend_module.start_session(workspace, start_opts)
  rescue
    _exception ->
      {:error,
       AgentServer.Error.new(:startup, "agent backend startup raised an exception",
         code: :backend_startup_exception,
         retryable?: true
       )}
  catch
    _kind, _reason ->
      {:error,
       AgentServer.Error.new(:startup, "agent backend startup terminated unexpectedly",
         code: :backend_startup_termination,
         retryable?: true
       )}
  end

  defp do_run_agent_turns(loop, session, issue, turn_number) do
    prompt = build_turn_prompt(issue, loop.opts, turn_number, loop.max_turns)

    case run_backend_turn(loop, session, prompt, issue) do
      {:ok, turn_session} ->
        updated_session = Map.get(turn_session, :session, session)
        Process.put(loop.final_session_marker, updated_session)

        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{loop.workspace} turn=#{turn_number}/#{loop.max_turns}")

        case continue_with_issue?(issue, loop.issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < loop.max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{loop.max_turns}")

            do_run_agent_turns(loop, updated_session, refreshed_issue, turn_number + 1)

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            {:ok, updated_session}

          {:done, _refreshed_issue} ->
            {:ok, updated_session}

          {:error, reason} ->
            {:error, AgentServer.normalize_error(reason, :tracker), updated_session}
        end

      {:error, reason} ->
        error = AgentServer.normalize_error(reason)
        {:error, error, session}
    end
  end

  defp run_backend_turn(loop, session, prompt, issue) do
    error_marker = make_ref()
    Process.put(error_marker, false)

    try do
      result =
        try do
          loop.backend_module.run_turn(
            session,
            prompt,
            issue,
            on_message: agent_message_handler(loop.agent_update_recipient, issue, loop.backend, error_marker)
          )
        rescue
          _exception ->
            {:error,
             AgentServer.Error.new(:provider, "agent backend turn raised an exception",
               code: :backend_turn_exception,
               retryable?: true
             )}
        catch
          _kind, _reason ->
            {:error,
             AgentServer.Error.new(:provider, "agent backend turn terminated unexpectedly",
               code: :backend_turn_termination,
               retryable?: true
             )}
        end

      case result do
        {:error, reason} ->
          error = AgentServer.normalize_error(reason)

          unless Process.get(error_marker) do
            send_agent_error(loop.agent_update_recipient, issue, loop.backend, :turn_failed, error)
          end

          {:error, error}

        other ->
          other
      end
    after
      Process.delete(error_marker)
    end
  end

  defp stop_session_safely(backend_module, session) do
    case backend_module.stop_session(session) do
      :ok -> :ok
      _other -> :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp final_session({:ok, session}), do: session
  defp final_session({:error, _reason, session}), do: session

  defp send_agent_error(recipient, issue, backend, type, error) do
    send_agent_update(recipient, issue, AgentServer.Event.new(backend, type, error: error))
  end

  defp normalize_turn_result({:ok, _session}), do: :ok
  defp normalize_turn_result({:error, reason, _session}), do: {:error, reason}

  defp safe_error_text(%AgentServer.Error{} = error) do
    "kind=#{error.kind} code=#{safe_error_code(error.code)}"
  end

  defp safe_error_code(code) when is_atom(code) or is_integer(code), do: to_string(code)
  defp safe_error_code(code) when is_binary(code), do: String.slice(code, 0, 120)
  defp safe_error_code(_code), do: "unknown"

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
