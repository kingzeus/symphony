defmodule SymphonyElixir.AgentRoute do
  @moduledoc """
  Resolves the effective backend and reasoning effort for an issue from labels.

  Labels use a `key::value` namespace so their meaning is self-describing:
  `backend::<registered_name>` (e.g. `backend::qoder`) selects the execution
  backend, and `effort::<level>` (e.g. `effort::high`) selects reasoning effort.
  Precedence is issue label > config default. Conflicting labels fall back to the
  default with a warning rather than silently picking one. Effort is normalized
  per backend (Codex has no tier above `xhigh`, so `max` collapses to `xhigh`).
  """

  alias SymphonyElixir.{AgentServer, Config}
  alias SymphonyElixir.Tracker.Issue

  @backend_prefix "backend::"
  @effort_prefix "effort::"
  @effort_values ["low", "medium", "high", "xhigh", "max"]

  defstruct [:backend, :effort, warnings: []]

  @type t :: %__MODULE__{
          backend: String.t(),
          effort: String.t() | nil,
          warnings: [String.t()]
        }

  @spec resolve(Issue.t(), term()) :: t()
  def resolve(%Issue{} = issue, settings \\ Config.settings!()) do
    labels =
      issue
      |> Issue.label_names()
      |> Enum.map(&normalize_label/1)
      |> Enum.reject(&is_nil/1)

    backend_matches =
      labels
      |> Enum.filter(&String.starts_with?(&1, @backend_prefix))
      |> Enum.map(&String.replace_prefix(&1, @backend_prefix, ""))
      |> Enum.filter(&registered_backend?/1)
      |> Enum.uniq()

    effort_matches =
      labels
      |> Enum.filter(&String.starts_with?(&1, @effort_prefix))
      |> Enum.map(&String.replace_prefix(&1, @effort_prefix, ""))
      |> Enum.filter(&(&1 in @effort_values))
      |> Enum.uniq()

    default_backend = settings.agent.backend
    default_effort = Map.get(settings.agent, :default_effort)

    {backend, backend_warnings} = resolve_one(backend_matches, default_backend, "backend")
    {effort, effort_warnings} = resolve_one(effort_matches, default_effort, "effort")

    %__MODULE__{
      backend: backend,
      effort: normalize_effort(backend, effort),
      warnings: backend_warnings ++ effort_warnings
    }
  end

  @spec effort_values() :: [String.t()]
  def effort_values, do: @effort_values

  defp resolve_one([single], _default, _kind), do: {single, []}
  defp resolve_one([], default, _kind), do: {default, []}

  defp resolve_one(conflicts, default, kind) do
    {default, ["multiple #{kind} labels (#{Enum.join(conflicts, ", ")}) found; falling back to default #{inspect(default)}"]}
  end

  defp registered_backend?(name) do
    name in Enum.map(AgentServer.backend_names(), &Atom.to_string/1)
  end

  # Codex natively supports low/medium/high/xhigh; "max" collapses to xhigh.
  defp normalize_effort("codex", "max"), do: "xhigh"
  defp normalize_effort(_backend, effort), do: effort

  defp normalize_label(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_label(_value), do: nil
end
