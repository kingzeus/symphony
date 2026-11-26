defmodule SymphonyElixir.AgentRouteTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRoute
  alias SymphonyElixir.Tracker.Issue

  defp issue(labels), do: %Issue{id: "i1", identifier: "TIK-1", labels: labels}

  defp settings(backend \\ "codex", default_effort \\ nil) do
    %{agent: %{backend: backend, default_effort: default_effort}}
  end

  test "无 label 走配置默认" do
    route = AgentRoute.resolve(issue([]), settings("qoder", "medium"))
    assert route.backend == "qoder"
    assert route.effort == "medium"
    assert route.warnings == []
  end

  test "backend::注册名 覆盖 backend" do
    route = AgentRoute.resolve(issue(["backend::qoder"]), settings("codex"))
    assert route.backend == "qoder"
  end

  test "effort::level 覆盖 effort" do
    route = AgentRoute.resolve(issue(["effort::high"]), settings("codex", "low"))
    assert route.effort == "high"
  end

  test "label 大小写/空白归一" do
    route = AgentRoute.resolve(issue(["  Backend::Qoder ", "EFFORT::High"]), settings())
    assert route.backend == "qoder"
    assert route.effort == "high"
  end

  test "未知 backend 名被忽略，走默认" do
    route = AgentRoute.resolve(issue(["backend::nonexistent"]), settings("codex"))
    assert route.backend == "codex"
    assert route.warnings == []
  end

  test "非法 effort 值被忽略" do
    route = AgentRoute.resolve(issue(["effort::ultra"]), settings("codex", "low"))
    assert route.effort == "low"
  end

  test "多个 backend label 冲突回退默认并 warning" do
    route = AgentRoute.resolve(issue(["backend::qoder", "backend::claude_code"]), settings("codex"))
    assert route.backend == "codex"
    assert length(route.warnings) == 1
    assert hd(route.warnings) =~ "multiple backend labels"
  end

  test "多个 effort label 冲突回退默认并 warning" do
    route = AgentRoute.resolve(issue(["effort::low", "effort::high"]), settings("codex", "medium"))
    assert route.effort == "medium"
    assert hd(route.warnings) =~ "multiple effort labels"
  end

  test "codex max 归一为 xhigh" do
    route = AgentRoute.resolve(issue(["effort::max"]), settings("codex"))
    assert route.effort == "xhigh"
  end

  test "非 codex backend max 保留" do
    route = AgentRoute.resolve(issue(["backend::qoder", "effort::max"]), settings())
    assert route.backend == "qoder"
    assert route.effort == "max"
  end

  test "无关 label 不影响路由" do
    route = AgentRoute.resolve(issue(["bug", "priority::high", "thinking::high"]), settings("codex"))
    assert route.backend == "codex"
    assert route.effort == nil
  end

  test "空白/非字符串 label 被忽略" do
    route = AgentRoute.resolve(issue(["   ", nil, 123]), settings("codex"))
    assert route.backend == "codex"
    assert route.effort == nil
    assert route.warnings == []
  end
end
