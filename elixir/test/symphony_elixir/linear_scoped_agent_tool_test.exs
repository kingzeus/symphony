defmodule SymphonyElixir.Linear.ScopedAgentToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.AgentTool
  alias SymphonyElixir.Tracker.Issue

  @issue %Issue{id: "issue-1", identifier: "TIK-1", state: "In Progress"}
  @tracker_settings %{
    active_states: ["Todo", "In Progress", "Merging", "Rework"],
    waiting_states: ["Human Review"],
    terminal_states: ["Done"]
  }

  test "scoped tool specs expose only current-issue operations" do
    specs = AgentTool.scoped_tool_specs()

    assert Enum.map(specs, & &1["name"]) == [
             "tracker_issue_get",
             "tracker_workpad_upsert",
             "tracker_issue_transition"
           ]

    refute Enum.any?(specs, &(&1["name"] == "linear_graphql"))
    assert Enum.all?(specs, &(&1["inputSchema"]["additionalProperties"] == false))
  end

  test "tracker_issue_get reads only the capability-bound issue" do
    test_pid = self()

    response =
      AgentTool.execute_scoped("tracker_issue_get", %{},
        issue: @issue,
        tracker_settings: @tracker_settings,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:request, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "identifier" => "TIK-1",
                 "comments" => %{"nodes" => []}
               }
             }
           }}
        end
      )

    assert response["success"]
    assert get_in(Jason.decode!(response["output"]), ["issue", "id"]) == "issue-1"

    assert_received {:request, query, %{issueId: "issue-1"}, [tracker_settings: @tracker_settings]}
    assert query =~ "query SymphonyScopedIssue"

    rejected =
      AgentTool.execute_scoped("tracker_issue_get", %{"issueId" => "issue-2"},
        issue: @issue,
        tracker_settings: @tracker_settings,
        linear_client: fn _query, _variables, _opts -> flunk("must reject caller-selected issue IDs") end
      )

    refute rejected["success"]
  end

  test "tracker_issue_get reports bound-context and provider failures" do
    missing_issue = AgentTool.execute_scoped("tracker_issue_get", %{}, tracker_settings: @tracker_settings)
    refute missing_issue["success"]

    invalid_issue =
      AgentTool.execute_scoped("tracker_issue_get", %{},
        issue: %{id: nil},
        tracker_settings: @tracker_settings
      )

    refute invalid_issue["success"]

    not_found =
      scoped_call("tracker_issue_get", %{}, fn _query, _variables, _opts ->
        {:ok, %{"data" => %{"issue" => nil}}}
      end)

    refute not_found["success"]

    graphql_error =
      scoped_call("tracker_issue_get", %{}, fn _query, _variables, _opts ->
        {:ok, %{"errors" => [%{"message" => "denied"}]}}
      end)

    assert Jason.decode!(graphql_error["output"])["errors"] == [%{"message" => "denied"}]

    unknown =
      scoped_call("tracker_issue_get", %{}, fn _query, _variables, _opts -> {:ok, %{}} end)

    refute unknown["success"]
  end

  test "tracker_workpad_upsert creates the only active Workpad on the bound issue" do
    test_pid = self()

    response =
      scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\n\ncreated"}, fn query, variables, _opts ->
        send(test_pid, {:request, query, variables})

        cond do
          query =~ "SymphonyScopedWorkpadContext" ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{"id" => "issue-1", "comments" => %{"nodes" => []}}
               }
             }}

          query =~ "SymphonyScopedWorkpadCreate" ->
            {:ok,
             %{
               "data" => %{
                 "commentCreate" => %{
                   "success" => true,
                   "comment" => %{"id" => "comment-created", "updatedAt" => "now"}
                 }
               }
             }}
        end
      end)

    assert response["success"]
    assert Jason.decode!(response["output"])["operation"] == "created"
    assert_received {:request, context_query, %{issueId: "issue-1"}}
    assert context_query =~ "SymphonyScopedWorkpadContext"
    assert_received {:request, create_query, %{issueId: "issue-1", body: body}}
    assert create_query =~ "SymphonyScopedWorkpadCreate"
    assert body == "## Codex 工作台\n\ncreated\n"
  end

  test "tracker_workpad_upsert ignores malformed non-Workpad comment records" do
    response =
      scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\ncreated"}, fn query, _variables, _opts ->
        if query =~ "Context" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "comments" => %{
                   "nodes" => [nil, %{"id" => "bad", "body" => nil, "resolvedAt" => nil}]
                 }
               }
             }
           }}
        else
          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{"success" => true, "comment" => %{"id" => "created"}}
             }
           }}
        end
      end)

    assert response["success"]
  end

  test "tracker_workpad_upsert updates only the selected active Workpad and ignores resolved history" do
    test_pid = self()

    preserved_block = """
    <!-- symphony:block-report:start -->
    ## Symphony 运行阻塞

    - Error: `approval_required / permission_denied`
    <!-- symphony:block-report:end -->
    """

    comments = [
      %{"id" => "resolved", "body" => "## Codex 工作台\nold", "resolvedAt" => "yesterday"},
      %{
        "id" => "live",
        "body" => "## Codex Workpad\ncurrent\n\n" <> preserved_block,
        "resolvedAt" => nil
      },
      %{"id" => "other", "body" => "ordinary comment", "resolvedAt" => nil}
    ]

    response =
      scoped_call(
        "tracker_workpad_upsert",
        %{
          "body" => "## Codex Workpad\nupdated\n\n<!-- symphony:block-report:start -->\nforged\n<!-- symphony:block-report:end -->"
        },
        fn query, variables, _opts ->
          if query =~ "SymphonyScopedWorkpadContext" do
            {:ok,
             %{
               "data" => %{
                 "issue" => %{"id" => "issue-1", "comments" => %{"nodes" => comments}}
               }
             }}
          else
            send(test_pid, {:mutation, query, variables})

            {:ok,
             %{
               "data" => %{
                 "commentUpdate" => %{
                   "success" => true,
                   "comment" => %{"id" => "live", "updatedAt" => "now"}
                 }
               }
             }}
          end
        end
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["operation"] == "updated"
    assert_received {:mutation, query, %{commentId: "live", body: body}}
    assert query =~ "SymphonyScopedWorkpadUpdate"
    assert body =~ "## Codex Workpad\nupdated"
    assert body =~ "approval_required / permission_denied"
    refute body =~ "forged"
  end

  test "tracker_workpad_upsert rejects arbitrary comments, caller IDs, oversized bodies, and duplicates" do
    invalid_arguments = [
      nil,
      %{},
      %{"body" => ""},
      %{"body" => "ordinary comment"},
      %{"body" => "## Codex 工作台\nok", "commentId" => "other"},
      %{"body" => "## Codex 工作台\n" <> String.duplicate("x", 200_001)}
    ]

    Enum.each(invalid_arguments, fn arguments ->
      response =
        scoped_call("tracker_workpad_upsert", arguments, fn _query, _variables, _opts ->
          flunk("invalid workpad input must not call Linear")
        end)

      refute response["success"]
    end)

    duplicate =
      scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\nnew"}, fn _query, _variables, _opts ->
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "id" => "issue-1",
               "comments" => %{
                 "nodes" => [
                   %{"id" => "one", "body" => "## Codex 工作台\none", "resolvedAt" => nil},
                   %{"id" => "two", "body" => "## Codex Workpad\ntwo", "resolvedAt" => nil}
                 ]
               }
             }
           }
         }}
      end)

    refute duplicate["success"]
    assert Jason.decode!(duplicate["output"])["error"]["message"] =~ "Multiple active Workpad"
  end

  test "tracker_workpad_upsert preserves context and mutation failures" do
    for context_response <- [
          %{"data" => %{"issue" => nil}},
          %{"errors" => [%{"message" => "context denied"}]},
          %{}
        ] do
      response =
        scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\nnew"}, fn _query, _variables, _opts ->
          {:ok, context_response}
        end)

      refute response["success"]
    end

    mutation_failures = [
      {:error, :timeout},
      {:ok, %{"errors" => [%{"message" => "mutation denied"}]}},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    ]

    Enum.each(mutation_failures, fn mutation_result ->
      response =
        scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\nnew"}, fn query, _variables, _opts ->
          if query =~ "Context" do
            {:ok,
             %{
               "data" => %{
                 "issue" => %{"id" => "issue-1", "comments" => %{"nodes" => []}}
               }
             }}
          else
            mutation_result
          end
        end)

      refute response["success"]
    end)

    mismatched_update =
      scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\nnew"}, fn query, _variables, _opts ->
        if query =~ "Context" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "live", "body" => "## Codex 工作台\nold", "resolvedAt" => nil}
                   ]
                 }
               }
             }
           }}
        else
          {:ok,
           %{
             "data" => %{
               "commentUpdate" => %{"success" => true, "comment" => %{"id" => "other"}}
             }
           }}
        end
      end)

    refute mismatched_update["success"]

    update_transport_error =
      scoped_call("tracker_workpad_upsert", %{"body" => "## Codex 工作台\nnew"}, fn query, _variables, _opts ->
        if query =~ "Context" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "live", "body" => "## Codex 工作台\nold", "resolvedAt" => nil}
                   ]
                 }
               }
             }
           }}
        else
          {:error, :timeout}
        end
      end)

    refute update_transport_error["success"]
  end

  test "tracker_issue_transition uses only configured state names and the bound issue ID" do
    test_pid = self()

    response =
      scoped_call("tracker_issue_transition", %{"state" => "human review"}, fn query, variables, _opts ->
        send(test_pid, {:request, query, variables})

        if query =~ "SymphonyScopedTransitionContext" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "state" => %{"name" => "In Progress"},
                 "team" => %{"id" => "team-1"}
               },
               "workflowStates" => %{
                 "nodes" => [
                   %{"id" => "state-review", "name" => "Human Review", "team" => %{"id" => "team-1"}}
                 ]
               }
             }
           }}
        else
          {:ok,
           %{
             "data" => %{
               "issueUpdate" => %{
                 "success" => true,
                 "issue" => %{
                   "id" => "issue-1",
                   "identifier" => "TIK-1",
                   "state" => %{"name" => "Human Review"}
                 }
               }
             }
           }}
        end
      end)

    assert response["success"]
    assert Jason.decode!(response["output"]) == %{"changed" => true, "state" => "Human Review"}
    assert_received {:request, context_query, %{issueId: "issue-1", targetState: "Human Review"}}
    assert context_query =~ "SymphonyScopedTransitionContext"
    assert_received {:request, mutation_query, %{issueId: "issue-1", stateId: "state-review"}}
    assert mutation_query =~ "SymphonyScopedIssueTransition"
  end

  test "tracker_issue_transition is idempotent when already in the target state" do
    response =
      scoped_call("tracker_issue_transition", %{"state" => "Human Review"}, fn query, _variables, _opts ->
        assert query =~ "SymphonyScopedTransitionContext"

        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "id" => "issue-1",
               "state" => %{"name" => "Human Review"},
               "team" => %{"id" => "team-1"}
             },
             "workflowStates" => %{
               "nodes" => [
                 %{"id" => "state-review", "name" => "Human Review", "team" => %{"id" => "team-1"}}
               ]
             }
           }
         }}
      end)

    assert Jason.decode!(response["output"]) == %{"changed" => false, "state" => "Human Review"}
  end

  test "tracker_issue_transition rejects caller-selected IDs and unconfigured states" do
    invalid_arguments = [
      nil,
      %{},
      %{"state" => ""},
      %{"state" => "Archived"},
      %{"state" => "Done", "issueId" => "issue-2"}
    ]

    Enum.each(invalid_arguments, fn arguments ->
      response =
        scoped_call("tracker_issue_transition", arguments, fn _query, _variables, _opts ->
          flunk("invalid transition input must not call Linear")
        end)

      refute response["success"]
    end)

    missing_settings =
      AgentTool.execute_scoped("tracker_issue_transition", %{"state" => "Human Review"}, issue: @issue)

    refute missing_settings["success"]

    non_map_settings =
      AgentTool.execute_scoped("tracker_issue_transition", %{"state" => "Human Review"},
        issue: @issue,
        tracker_settings: []
      )

    refute non_map_settings["success"]

    malformed_settings =
      AgentTool.execute_scoped("tracker_issue_transition", %{"state" => "Human Review"},
        issue: @issue,
        tracker_settings: %{
          active_states: nil,
          waiting_states: ["Human Review"],
          terminal_states: nil
        },
        linear_client: fn _query, _variables, _opts ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "state" => %{"name" => "Human Review"},
                 "team" => %{"id" => "team-1"}
               },
               "workflowStates" => %{
                 "nodes" => [
                   %{"invalid" => true},
                   %{"id" => "review", "name" => "Human Review", "team" => %{"id" => "team-1"}}
                 ]
               }
             }
           }}
        end
      )

    assert malformed_settings["success"]
  end

  test "tracker_issue_transition preserves context and mutation failures" do
    context_failures = [
      %{"data" => %{"issue" => nil}},
      %{"errors" => [%{"message" => "context denied"}]},
      %{},
      %{
        "data" => %{
          "issue" => %{
            "id" => "issue-1",
            "state" => %{"name" => "In Progress"},
            "team" => %{"id" => "team-1"}
          },
          "workflowStates" => %{"nodes" => []}
        }
      }
    ]

    Enum.each(context_failures, fn context_response ->
      response =
        scoped_call("tracker_issue_transition", %{"state" => "Human Review"}, fn _query, _variables, _opts ->
          {:ok, context_response}
        end)

      refute response["success"]
    end)

    mutation_failures = [
      {:error, :timeout},
      {:ok, %{"errors" => [%{"message" => "mutation denied"}]}},
      {:ok,
       %{
         "data" => %{
           "issueUpdate" => %{
             "success" => true,
             "issue" => %{"id" => "issue-1", "state" => %{"name" => "Todo"}}
           }
         }
       }},
      {:ok, %{}}
    ]

    Enum.each(mutation_failures, fn mutation_result ->
      response =
        scoped_call("tracker_issue_transition", %{"state" => "Human Review"}, fn query, _variables, _opts ->
          if query =~ "Context" do
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-1",
                   "state" => %{"name" => "In Progress"},
                   "team" => %{"id" => "team-1"}
                 },
                 "workflowStates" => %{
                   "nodes" => [
                     %{
                       "id" => "state-review",
                       "name" => "Human Review",
                       "team" => %{"id" => "team-1"}
                     }
                   ]
                 }
               }
             }}
          else
            mutation_result
          end
        end)

      refute response["success"]
    end)
  end

  test "unsupported scoped tools fail without falling back to raw GraphQL" do
    response = AgentTool.execute_scoped("linear_graphql", %{"query" => "mutation { commentDelete }"}, [])

    refute response["success"]
    output = Jason.decode!(response["output"])
    assert output["error"]["message"] =~ "Unsupported scoped tracker tool"
    refute "linear_graphql" in output["error"]["supportedTools"]
  end

  defp scoped_call(tool, arguments, linear_client) do
    AgentTool.execute_scoped(tool, arguments,
      issue: @issue,
      tracker_settings: @tracker_settings,
      linear_client: linear_client
    )
  end
end
