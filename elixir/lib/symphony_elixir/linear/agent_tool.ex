defmodule SymphonyElixir.Linear.AgentTool do
  @moduledoc """
  Provider-native Linear tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.PathSafety

  @linear_graphql_tool "linear_graphql"
  @scoped_issue_get_tool "tracker_issue_get"
  @scoped_workpad_upsert_tool "tracker_workpad_upsert"
  @scoped_issue_transition_tool "tracker_issue_transition"
  @max_workpad_body_bytes 200_000
  @blocked_report_start "<!-- symphony:block-report:start -->"
  @blocked_report_end "<!-- symphony:block-report:end -->"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @scoped_issue_query """
  query SymphonyScopedIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      title
      url
      state { name type }
      labels { nodes { name } }
      project { id name }
      team { id key }
      comments(first: 100) {
        nodes {
          id
          body
          createdAt
          updatedAt
          resolvedAt
          user { name }
        }
      }
    }
  }
  """

  @scoped_workpad_context_query """
  query SymphonyScopedWorkpadContext($issueId: String!) {
    issue(id: $issueId) {
      id
      comments(first: 100) {
        nodes { id body resolvedAt }
      }
    }
  }
  """

  @scoped_workpad_create_mutation """
  mutation SymphonyScopedWorkpadCreate($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id updatedAt }
    }
  }
  """

  @scoped_workpad_update_mutation """
  mutation SymphonyScopedWorkpadUpdate($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment { id updatedAt }
    }
  }
  """

  @scoped_transition_context_query """
  query SymphonyScopedTransitionContext($issueId: String!, $targetState: String!) {
    issue(id: $issueId) {
      id
      state { name }
      team { id }
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

  @scoped_transition_mutation """
  mutation SymphonyScopedIssueTransition($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
      issue { id identifier state { name } }
    }
  }
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  @doc """
  Returns the issue-scoped tools exposed through the Claude Tracker MCP bridge.

  These tools never accept raw GraphQL, issue IDs, comment IDs, or state IDs.
  Symphony derives every target from the turn capability and fixed host queries.
  """
  @spec scoped_tool_specs() :: [map()]
  def scoped_tool_specs do
    [
      %{
        "name" => @scoped_issue_get_tool,
        "description" => "Read the current capability-bound Linear issue and its comments.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{}
        }
      },
      %{
        "name" => @scoped_workpad_upsert_tool,
        "description" =>
          "Create or update the single active Workpad on the current capability-bound Linear issue. " <>
            "Provide either `body` inline or `file_path` to read the body from a local file in the issue workspace " <>
            "(maintain the workpad as a local file and sync at milestones to keep context small).",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "body" => %{
              "type" => "string",
              "maxLength" => @max_workpad_body_bytes,
              "description" => "Complete Workpad Markdown beginning with `## Codex 工作台` or `## Codex Workpad`. Mutually exclusive with `file_path`."
            },
            "file_path" => %{
              "type" => "string",
              "description" =>
                "Workspace-relative path to a local Markdown file whose contents become the Workpad body " <>
                  "(e.g. `workpad.md`). Must stay inside the issue workspace. Mutually exclusive with `body`."
            }
          }
        }
      },
      %{
        "name" => @scoped_issue_transition_tool,
        "description" => "Move the current capability-bound Linear issue to a configured workflow state by name.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["state"],
          "properties" => %{
            "state" => %{
              "type" => "string",
              "description" => "Target state name from the workflow's configured active, waiting, or terminal states."
            }
          }
        }
      }
    ]
  end

  @spec execute_scoped(String.t() | nil, term(), keyword()) :: map()
  def execute_scoped(tool, arguments, opts) do
    case tool do
      @scoped_issue_get_tool -> execute_scoped_issue_get(arguments, opts)
      @scoped_workpad_upsert_tool -> execute_scoped_workpad_upsert(arguments, opts)
      @scoped_issue_transition_tool -> execute_scoped_issue_transition(arguments, opts)
      other -> unsupported_scoped_tool_response(other)
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, client_opts) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_scoped_issue_get(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with :ok <- validate_argument_keys(arguments, []),
         {:ok, issue_id} <- scoped_issue_id(opts),
         {:ok, response} <- linear_client.(@scoped_issue_query, %{issueId: issue_id}, client_opts),
         {:ok, issue} <- decode_scoped_issue(response, issue_id) do
      success_payload(%{"issue" => issue})
    else
      {:error, reason} -> scoped_failure_response(reason)
    end
  end

  defp execute_scoped_workpad_upsert(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with :ok <- validate_argument_keys(arguments, ["body", "file_path"]),
         {:ok, body} <- normalize_workpad_body(arguments, opts),
         {:ok, issue_id} <- scoped_issue_id(opts),
         {:ok, context_response} <-
           linear_client.(@scoped_workpad_context_query, %{issueId: issue_id}, client_opts),
         {:ok, workpad} <- decode_workpad_context(context_response, issue_id),
         {:ok, persisted_body} <- preserve_host_managed_workpad_sections(workpad, body),
         {:ok, operation, response} <-
           upsert_scoped_workpad(linear_client, client_opts, issue_id, workpad, persisted_body),
         {:ok, comment} <- decode_workpad_mutation(response, operation, workpad) do
      success_payload(%{"operation" => Atom.to_string(operation), "comment" => comment})
    else
      {:error, reason} -> scoped_failure_response(reason)
    end
  end

  defp execute_scoped_issue_transition(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with :ok <- validate_argument_keys(arguments, ["state"]),
         {:ok, target_state} <- normalize_target_state(arguments, opts),
         {:ok, issue_id} <- scoped_issue_id(opts),
         {:ok, context_response} <-
           linear_client.(
             @scoped_transition_context_query,
             %{issueId: issue_id, targetState: target_state},
             client_opts
           ),
         {:ok, context} <- decode_transition_context(context_response, issue_id, target_state),
         {:ok, result} <-
           transition_scoped_issue(linear_client, client_opts, issue_id, target_state, context) do
      success_payload(result)
    else
      {:error, reason} -> scoped_failure_response(reason)
    end
  end

  defp validate_argument_keys(arguments, allowed_keys) when is_map(arguments) do
    normalized_keys = Enum.map(Map.keys(arguments), &to_string/1)

    if Enum.all?(normalized_keys, &(&1 in allowed_keys)) do
      :ok
    else
      {:error, :invalid_scoped_arguments}
    end
  end

  defp validate_argument_keys(_arguments, _allowed_keys), do: {:error, :invalid_scoped_arguments}

  defp scoped_issue_id(opts) do
    case Keyword.get(opts, :issue) do
      issue when is_map(issue) ->
        case Map.get(issue, :id) || Map.get(issue, "id") do
          issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
          _other -> {:error, :missing_scoped_issue}
        end

      _other ->
        {:error, :missing_scoped_issue}
    end
  end

  defp decode_scoped_issue(%{"data" => %{"issue" => %{"id" => issue_id} = issue}}, issue_id),
    do: {:ok, issue}

  defp decode_scoped_issue(%{"data" => %{"issue" => nil}}, _issue_id),
    do: {:error, :scoped_issue_not_found}

  defp decode_scoped_issue(%{"errors" => errors} = response, _issue_id) when is_list(errors),
    do: {:error, {:graphql_response, response}}

  defp decode_scoped_issue(_response, _issue_id), do: {:error, :linear_unknown_payload}

  defp normalize_workpad_body(arguments, opts) do
    with {:ok, raw_body} <- workpad_body_source(arguments, opts) do
      validate_workpad_body(raw_body)
    end
  end

  defp workpad_body_source(arguments, opts) do
    body = Map.get(arguments, "body") || Map.get(arguments, :body)
    file_path = Map.get(arguments, "file_path") || Map.get(arguments, :file_path)

    cond do
      is_binary(file_path) and file_path != "" ->
        if is_binary(body) and body != "" do
          {:error, :workpad_body_and_file_path}
        else
          read_workpad_file(file_path, Keyword.get(opts, :workspace))
        end

      is_binary(body) ->
        {:ok, body}

      true ->
        {:error, :invalid_workpad_body}
    end
  end

  defp read_workpad_file(file_path, workspace) when is_binary(workspace) and workspace != "" do
    if String.starts_with?(file_path, "/") do
      {:error, :workpad_file_absolute_path}
    else
      candidate = Path.join(workspace, file_path)

      with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
           {:ok, canonical_file} <- PathSafety.canonicalize(candidate) do
        read_descendant_file(canonical_file, canonical_workspace)
      else
        {:error, reason} -> {:error, {:workpad_file_read, reason}}
      end
    end
  end

  defp read_workpad_file(_file_path, _workspace), do: {:error, :missing_scoped_workspace}

  defp read_descendant_file(canonical_file, canonical_workspace) do
    if descendant_path?(canonical_file, canonical_workspace) do
      case File.read(canonical_file) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, {:workpad_file_read, reason}}
      end
    else
      {:error, :workpad_file_outside_workspace}
    end
  end

  defp descendant_path?(path, root),
    do: String.starts_with?(path <> "/", root <> "/") and path != root

  defp validate_workpad_body(body) when is_binary(body) do
    trimmed_body = String.trim(body)

    cond do
      trimmed_body == "" -> {:error, :invalid_workpad_body}
      byte_size(body) > @max_workpad_body_bytes -> {:error, :workpad_body_too_large}
      not workpad_body?(trimmed_body) -> {:error, :invalid_workpad_header}
      true -> {:ok, trimmed_body <> "\n"}
    end
  end

  defp decode_workpad_context(
         %{"data" => %{"issue" => %{"id" => issue_id, "comments" => %{"nodes" => comments}}}},
         issue_id
       )
       when is_list(comments) do
    workpads = Enum.filter(comments, &active_workpad?/1)

    case workpads do
      [] -> {:ok, nil}
      [%{"id" => id} = workpad] when is_binary(id) -> {:ok, workpad}
      [_first | _rest] -> {:error, :multiple_active_workpads}
    end
  end

  defp decode_workpad_context(%{"data" => %{"issue" => nil}}, _issue_id),
    do: {:error, :scoped_issue_not_found}

  defp decode_workpad_context(%{"errors" => errors} = response, _issue_id) when is_list(errors),
    do: {:error, {:graphql_response, response}}

  defp decode_workpad_context(_response, _issue_id), do: {:error, :linear_unknown_payload}

  defp active_workpad?(comment) when is_map(comment) do
    is_nil(Map.get(comment, "resolvedAt")) and workpad_body?(Map.get(comment, "body"))
  end

  defp active_workpad?(_comment), do: false

  defp workpad_body?(body) when is_binary(body) do
    Regex.match?(~r/\A## Codex (工作台|Workpad)\s*(?:\r?\n|\z)/, body)
  end

  defp workpad_body?(_body), do: false

  defp preserve_host_managed_workpad_sections(workpad, body) do
    preserved_section =
      case workpad do
        %{"body" => existing_body} when is_binary(existing_body) -> extract_blocked_report(existing_body)
        _other -> nil
      end

    agent_body = strip_blocked_reports(body) |> String.trim_trailing()

    persisted_body =
      case preserved_section do
        section when is_binary(section) -> agent_body <> "\n\n" <> section <> "\n"
        nil -> agent_body <> "\n"
      end

    if byte_size(persisted_body) <= @max_workpad_body_bytes do
      {:ok, persisted_body}
    else
      {:error, :workpad_body_too_large}
    end
  end

  defp extract_blocked_report(body) do
    case Regex.run(blocked_report_pattern(), body) do
      [section] -> section
      _other -> nil
    end
  end

  defp strip_blocked_reports(body), do: Regex.replace(blocked_report_pattern(), body, "")

  defp blocked_report_pattern do
    Regex.compile!(
      Regex.escape(@blocked_report_start) <> ".*?" <> Regex.escape(@blocked_report_end),
      "s"
    )
  end

  defp upsert_scoped_workpad(linear_client, client_opts, issue_id, nil, body) do
    case linear_client.(
           @scoped_workpad_create_mutation,
           %{issueId: issue_id, body: body},
           client_opts
         ) do
      {:ok, response} -> {:ok, :created, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_scoped_workpad(linear_client, client_opts, _issue_id, %{"id" => comment_id}, body) do
    case linear_client.(
           @scoped_workpad_update_mutation,
           %{commentId: comment_id, body: body},
           client_opts
         ) do
      {:ok, response} -> {:ok, :updated, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_workpad_mutation(
         %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => id} = comment}}},
         :created,
         nil
       )
       when is_binary(id),
       do: {:ok, comment}

  defp decode_workpad_mutation(
         %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => id} = comment}}},
         :updated,
         %{"id" => id}
       )
       when is_binary(id),
       do: {:ok, comment}

  defp decode_workpad_mutation(%{"errors" => errors} = response, _operation, _workpad)
       when is_list(errors),
       do: {:error, {:graphql_response, response}}

  defp decode_workpad_mutation(_response, _operation, _workpad),
    do: {:error, :linear_unknown_payload}

  defp normalize_target_state(arguments, opts) do
    with state when is_binary(state) <- Map.get(arguments, "state") || Map.get(arguments, :state),
         normalized when normalized != "" <- normalize_state_name(state),
         tracker_settings when is_map(tracker_settings) <- Keyword.get(opts, :tracker_settings),
         allowed_states when is_list(allowed_states) <- configured_states(tracker_settings),
         target_state when is_binary(target_state) <-
           Enum.find(allowed_states, &(normalize_state_name(&1) == normalized)) do
      {:ok, target_state}
    else
      nil -> {:error, :target_state_not_allowed}
      "" -> {:error, :invalid_target_state}
      _other -> {:error, :invalid_target_state}
    end
  end

  defp configured_states(tracker_settings) do
    [:active_states, :waiting_states, :terminal_states]
    |> Enum.flat_map(fn key ->
      case Map.get(tracker_settings, key) || Map.get(tracker_settings, Atom.to_string(key)) do
        states when is_list(states) -> states
        _other -> []
      end
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq_by(&normalize_state_name/1)
  end

  defp decode_transition_context(
         %{
           "data" => %{
             "issue" => %{
               "id" => issue_id,
               "state" => %{"name" => current_state},
               "team" => %{"id" => team_id}
             },
             "workflowStates" => %{"nodes" => states}
           }
         },
         issue_id,
         target_state
       )
       when is_binary(current_state) and is_binary(team_id) and is_list(states) do
    target =
      Enum.find(states, fn
        %{"id" => state_id, "name" => state_name, "team" => %{"id" => state_team_id}}
        when is_binary(state_id) and is_binary(state_name) and is_binary(state_team_id) ->
          state_team_id == team_id and normalize_state_name(state_name) == normalize_state_name(target_state)

        _other ->
          false
      end)

    case target do
      %{"id" => state_id} -> {:ok, %{current_state: current_state, target_state_id: state_id}}
      nil -> {:error, :target_state_not_found}
    end
  end

  defp decode_transition_context(%{"data" => %{"issue" => nil}}, _issue_id, _target_state),
    do: {:error, :scoped_issue_not_found}

  defp decode_transition_context(%{"errors" => errors} = response, _issue_id, _target_state)
       when is_list(errors),
       do: {:error, {:graphql_response, response}}

  defp decode_transition_context(_response, _issue_id, _target_state),
    do: {:error, :linear_unknown_payload}

  defp transition_scoped_issue(
         linear_client,
         client_opts,
         issue_id,
         target_state,
         %{current_state: current_state, target_state_id: state_id}
       ) do
    if normalize_state_name(current_state) == normalize_state_name(target_state) do
      {:ok, %{"changed" => false, "state" => current_state}}
    else
      with {:ok, response} <-
             linear_client.(
               @scoped_transition_mutation,
               %{issueId: issue_id, stateId: state_id},
               client_opts
             ) do
        decode_transition_mutation(response, issue_id, target_state)
      end
    end
  end

  defp decode_transition_mutation(
         %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"id" => issue_id, "state" => %{"name" => state_name}}
             }
           }
         },
         issue_id,
         target_state
       )
       when is_binary(state_name) do
    if normalize_state_name(state_name) == normalize_state_name(target_state) do
      {:ok, %{"changed" => true, "state" => state_name}}
    else
      {:error, :linear_state_mismatch}
    end
  end

  defp decode_transition_mutation(%{"errors" => errors} = response, _issue_id, _target_state)
       when is_list(errors),
       do: {:error, {:graphql_response, response}}

  defp decode_transition_mutation(_response, _issue_id, _target_state),
    do: {:error, :linear_unknown_payload}

  defp normalize_state_name(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp success_payload(payload), do: dynamic_tool_response(true, encode_payload(payload))

  defp scoped_failure_response({:graphql_response, response}), do: failure_response(response)
  defp scoped_failure_response(reason), do: failure_response(scoped_tool_error_payload(reason))

  defp scoped_tool_error_payload(:invalid_scoped_arguments) do
    %{"error" => %{"message" => "Scoped tracker tool arguments do not match the advertised schema."}}
  end

  defp scoped_tool_error_payload(:missing_scoped_issue) do
    %{"error" => %{"message" => "The tracker capability is missing its bound issue context."}}
  end

  defp scoped_tool_error_payload(:scoped_issue_not_found) do
    %{"error" => %{"message" => "The capability-bound Linear issue was not found."}}
  end

  defp scoped_tool_error_payload(:invalid_workpad_body) do
    %{"error" => %{"message" => "`tracker_workpad_upsert.body` must be a non-empty string."}}
  end

  defp scoped_tool_error_payload(:workpad_body_too_large) do
    %{"error" => %{"message" => "The Workpad body exceeds the 200000-byte limit."}}
  end

  defp scoped_tool_error_payload(:invalid_workpad_header) do
    %{
      "error" => %{
        "message" => "The Workpad body must begin with `## Codex 工作台` or `## Codex Workpad`."
      }
    }
  end

  defp scoped_tool_error_payload(:workpad_body_and_file_path) do
    %{
      "error" => %{
        "message" => "`tracker_workpad_upsert` accepts either `body` or `file_path`, not both."
      }
    }
  end

  defp scoped_tool_error_payload(:workpad_file_absolute_path) do
    %{
      "error" => %{
        "message" => "`tracker_workpad_upsert.file_path` must be relative to the issue workspace."
      }
    }
  end

  defp scoped_tool_error_payload(:workpad_file_outside_workspace) do
    %{
      "error" => %{
        "message" => "`tracker_workpad_upsert.file_path` must stay inside the issue workspace."
      }
    }
  end

  defp scoped_tool_error_payload(:missing_scoped_workspace) do
    %{
      "error" => %{
        "message" => "`tracker_workpad_upsert.file_path` requires a bound issue workspace; use `body` instead."
      }
    }
  end

  defp scoped_tool_error_payload({:workpad_file_read, reason}) do
    detail =
      if is_atom(reason) do
        to_string(:file.format_error(reason))
      else
        inspect(reason)
      end

    %{"error" => %{"message" => "Cannot read the Workpad file: #{detail}."}}
  end

  defp scoped_tool_error_payload(:multiple_active_workpads) do
    %{
      "error" => %{
        "message" => "Multiple active Workpad comments exist; refusing to choose or delete one automatically."
      }
    }
  end

  defp scoped_tool_error_payload(:invalid_target_state) do
    %{"error" => %{"message" => "`tracker_issue_transition.state` must be a non-empty configured state name."}}
  end

  defp scoped_tool_error_payload(:target_state_not_allowed) do
    %{
      "error" => %{
        "message" => "The requested state is outside the workflow's configured active, waiting, and terminal states."
      }
    }
  end

  defp scoped_tool_error_payload(:target_state_not_found) do
    %{"error" => %{"message" => "The requested state was not found for the capability-bound issue's team."}}
  end

  defp scoped_tool_error_payload(:linear_state_mismatch) do
    %{"error" => %{"message" => "Linear returned a different state after the scoped issue transition."}}
  end

  defp scoped_tool_error_payload(:linear_unknown_payload), do: tool_error_payload(:linear_unknown_payload)
  defp scoped_tool_error_payload(reason), do: tool_error_payload(reason)

  defp unsupported_scoped_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported scoped tracker tool: #{inspect(tool)}.",
        "supportedTools" => Enum.map(scoped_tool_specs(), & &1["name"])
      }
    })
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
