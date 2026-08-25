defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @blocked_report_context_query """
  query SymphonyLinearBlockedReportContext($issueId: String!, $targetState: String!) {
    issue(id: $issueId) {
      id
      identifier
      state { name }
      team { id }
      comments(first: 100) {
        nodes { id body }
      }
    }
    workflowStates(filter: {name: {eq: $targetState}}, first: 50) {
      nodes {
        id
        name
        team { id }
      }
    }
  }
  """

  @blocked_comment_create_mutation """
  mutation SymphonyLinearBlockedCommentCreate($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id body }
    }
  }
  """

  @blocked_comment_update_mutation """
  mutation SymphonyLinearBlockedCommentUpdate($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment { id body }
    }
  }
  """

  @blocked_issue_state_mutation """
  mutation SymphonyLinearBlockedIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
      issue { id identifier state { name } }
    }
  }
  """

  @blocked_report_start "<!-- symphony:block-report:start -->"
  @blocked_report_end "<!-- symphony:block-report:end -->"

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      states ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(tracker.project_slug, states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, tracker.project_slug, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(request_payload, headers, tracker_settings.endpoint)
      end)

    with {:ok, headers} <- graphql_headers(tracker_settings),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec report_blocked_issue(Issue.t(), map()) :: {:ok, Issue.t()} | {:error, term()}
  def report_blocked_issue(%Issue{} = issue, report) when is_map(report) do
    do_report_blocked_issue(issue, report, &graphql/2)
  end

  @doc false
  @spec report_blocked_issue_for_test(
          Issue.t(),
          map(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, Issue.t()} | {:error, term()}
  def report_blocked_issue_for_test(%Issue{} = issue, report, graphql_fun)
      when is_map(report) and is_function(graphql_fun, 2) do
    do_report_blocked_issue(issue, report, graphql_fun)
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, "test-project", nil, graphql_fun)
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_report_blocked_issue(%Issue{} = issue, report, graphql_fun) do
    target_state = Map.get(report, :target_state)

    with :ok <- validate_blocked_report(issue, target_state),
         {:ok, context_body} <-
           graphql_fun.(@blocked_report_context_query, %{
             issueId: issue.id,
             targetState: target_state
           }),
         {:ok, context} <- decode_blocked_report_context(context_body, target_state),
         :ok <- upsert_blocked_workpad(issue, report, context, graphql_fun) do
      transition_blocked_issue(issue, target_state, context, graphql_fun)
    end
  end

  defp validate_blocked_report(%Issue{id: issue_id}, target_state) do
    cond do
      not present_string?(issue_id) -> {:error, :linear_blocked_report_missing_issue_id}
      not present_string?(target_state) -> {:error, :missing_tracker_waiting_state}
      true -> :ok
    end
  end

  defp decode_blocked_report_context(
         %{
           "data" => %{
             "issue" => %{
               "id" => issue_id,
               "team" => %{"id" => team_id},
               "state" => %{"name" => current_state},
               "comments" => %{"nodes" => comments}
             },
             "workflowStates" => %{"nodes" => states}
           }
         },
         target_state
       )
       when is_binary(issue_id) and is_binary(team_id) and is_binary(current_state) and
              is_list(comments) and is_list(states) do
    case find_matching_workflow_state(states, team_id, target_state) do
      %{"id" => state_id} ->
        {:ok,
         %{
           current_state: current_state,
           target_state_id: state_id,
           comments: comments
         }}

      nil ->
        {:error, {:linear_missing_blocked_report_state, target_state}}
    end
  end

  defp decode_blocked_report_context(%{"errors" => errors}, _target_state) when is_list(errors) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_blocked_report_context(_body, _target_state), do: {:error, :linear_unknown_payload}

  defp find_matching_workflow_state(states, team_id, target_state) do
    Enum.find(states, &workflow_state_matches?(&1, team_id, target_state))
  end

  defp workflow_state_matches?(
         %{"id" => state_id, "name" => state_name, "team" => %{"id" => state_team_id}},
         team_id,
         target_state
       )
       when is_binary(state_id) and is_binary(state_name) and is_binary(state_team_id) do
    state_team_id == team_id and normalize_state_name(state_name) == normalize_state_name(target_state)
  end

  defp workflow_state_matches?(_state, _team_id, _target_state), do: false

  defp upsert_blocked_workpad(%Issue{} = issue, report, context, graphql_fun) do
    section = blocked_report_section(issue, report)

    case find_workpad_comment(context.comments) do
      %{"id" => comment_id, "body" => body} when is_binary(comment_id) and is_binary(body) ->
        updated_body = replace_or_append_blocked_report(body, section)

        graphql_fun.(@blocked_comment_update_mutation, %{
          commentId: comment_id,
          body: updated_body
        })
        |> decode_comment_mutation("commentUpdate")

      _ ->
        body = "## Codex 工作台\n\n" <> section <> "\n"

        graphql_fun.(@blocked_comment_create_mutation, %{
          issueId: issue.id,
          body: body
        })
        |> decode_comment_mutation("commentCreate")
    end
  end

  defp find_workpad_comment(comments) when is_list(comments) do
    Enum.find(comments, fn
      %{"body" => body} when is_binary(body) ->
        Regex.match?(~r/^## Codex (工作台|Workpad)\s*$/m, body)

      _ ->
        false
    end)
  end

  defp decode_comment_mutation({:ok, %{"data" => data}}, operation) when is_map(data) do
    case Map.get(data, operation) do
      %{"success" => true, "comment" => %{"id" => id}} when is_binary(id) ->
        :ok

      _ ->
        {:error, :linear_unknown_payload}
    end
  end

  defp decode_comment_mutation({:ok, %{"errors" => errors}}, _operation) when is_list(errors) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_comment_mutation({:ok, _body}, _operation), do: {:error, :linear_unknown_payload}
  defp decode_comment_mutation({:error, reason}, _operation), do: {:error, reason}

  defp transition_blocked_issue(%Issue{} = issue, target_state, context, graphql_fun) do
    if normalize_state_name(context.current_state) == normalize_state_name(target_state) do
      {:ok, %{issue | state: target_state, updated_at: DateTime.utc_now()}}
    else
      graphql_fun.(@blocked_issue_state_mutation, %{
        issueId: issue.id,
        stateId: context.target_state_id
      })
      |> decode_issue_state_mutation(issue, target_state)
    end
  end

  defp decode_issue_state_mutation(
         {:ok,
          %{
            "data" => %{
              "issueUpdate" => %{
                "success" => true,
                "issue" => %{"id" => issue_id, "state" => %{"name" => state_name}}
              }
            }
          }},
         %Issue{id: issue_id} = issue,
         target_state
       )
       when is_binary(state_name) do
    if normalize_state_name(state_name) == normalize_state_name(target_state) do
      {:ok, %{issue | state: state_name, updated_at: DateTime.utc_now()}}
    else
      {:error, {:linear_blocked_report_state_mismatch, state_name}}
    end
  end

  defp decode_issue_state_mutation({:ok, %{"errors" => errors}}, _issue, _target_state)
       when is_list(errors) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_issue_state_mutation({:ok, _body}, _issue, _target_state),
    do: {:error, :linear_unknown_payload}

  defp decode_issue_state_mutation({:error, reason}, _issue, _target_state), do: {:error, reason}

  defp blocked_report_section(%Issue{} = issue, report) do
    error = Map.get(report, :typed_error) || %{}
    approval = Map.get(report, :approval) || %{}

    [
      @blocked_report_start,
      "## Symphony 运行阻塞",
      "",
      "- Issue: `#{safe_inline(issue.identifier || issue.id)}`",
      "- 状态: `blocked`",
      "- 目标 Linear 状态: `#{safe_inline(Map.get(report, :target_state))}`",
      "- Backend: `#{safe_inline(Map.get(report, :backend))}`",
      "- Error: `#{safe_inline(Map.get(error, :kind))} / #{safe_inline(Map.get(error, :code))}`",
      "- Message: #{safe_inline(Map.get(report, :message))}",
      "- Approval: `#{safe_inline(Map.get(approval, :kind))} / #{safe_inline(Map.get(approval, :status))}`",
      "- Session: `#{safe_inline(Map.get(report, :session_id))}`",
      "- Workspace: `#{safe_inline(Map.get(report, :workspace_path))}`",
      "- Blocked at: `#{safe_inline(format_datetime(Map.get(report, :blocked_at)))}`",
      "- 处理: Symphony 已停止自动重试，等待人工处理；未记录原始 prompt、tool input 或凭据。",
      @blocked_report_end
    ]
    |> Enum.join("\n")
  end

  defp replace_or_append_blocked_report(body, section) do
    pattern =
      Regex.compile!(
        Regex.escape(@blocked_report_start) <> ".*?" <> Regex.escape(@blocked_report_end),
        "s"
      )

    if Regex.match?(pattern, body) do
      Regex.replace(pattern, body, section)
    else
      String.trim_trailing(body) <> "\n\n" <> section <> "\n"
    end
  end

  defp safe_inline(nil), do: "n/a"

  defp safe_inline(value) do
    value
    |> to_string()
    |> String.replace(["\r", "\n", "`"], " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
    |> case do
      "" -> "n/a"
      text -> text
    end
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value), do: value

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, project_slug, assignee_filter) do
    do_fetch_issue_states(ids, project_slug, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, project_slug, assignee_filter, graphql_fun)
       when is_list(ids) and is_binary(project_slug) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, project_slug, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _project_slug, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, project_slug, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           projectSlug: project_slug,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            project_slug,
            assignee_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(tracker_settings) do
    case tracker_settings.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers, endpoint) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :drop_malformed)
  end

  defp decode_linear_response_strict(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :error_on_malformed)
  end

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         malformed_policy
       )
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))

    malformed_count = Enum.count(issues, &is_nil/1)

    case {malformed_policy, malformed_count > 0} do
      {:error_on_malformed, true} ->
        {:error, :linear_unknown_payload}

      {:drop_malformed, true} ->
        Logger.warning("Dropping malformed Linear issue records count=#{malformed_count}")
        {:ok, Enum.reject(issues, &is_nil/1)}

      {:drop_malformed, false} ->
        {:ok, issues}

      {_, false} ->
        {:ok, issues}
    end
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _malformed_policy) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _malformed_policy) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    state_name = get_in(issue, ["state", "name"])

    if Enum.all?([issue["id"], issue["identifier"], issue["title"], state_name], &present_string?/1) do
      assignee = issue["assignee"]
      blockers = extract_blockers(issue)

      %Issue{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: state_name,
        branch_name: issue["branchName"],
        url: issue["url"],
        assignee_id: assignee_field(assignee, "id"),
        blocked_by: blockers,
        labels: extract_labels(issue),
        dispatchable: dispatchable?(state_name, blockers, assignee, assignee_filter),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp dispatchable?(state_name, blockers, assignee, assignee_filter) do
    assigned_to_worker?(assignee, assignee_filter) and
      not blocked_before_dispatch?(state_name, blockers)
  end

  defp blocked_before_dispatch?(state_name, blockers)
       when is_binary(state_name) and is_list(blockers) do
    normalize_state_name(state_name) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not terminal_state?(blocker_state)

        _ ->
          true
      end)
  end

  defp blocked_before_dispatch?(_state_name, _blockers), do: false

  defp terminal_state?(state_name) when is_binary(state_name) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_state_name/1)
      |> MapSet.new()

    MapSet.member?(terminal_states, normalize_state_name(state_name))
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_linear_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> {:ok, tracker}
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
