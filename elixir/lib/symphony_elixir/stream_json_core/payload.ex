defmodule SymphonyElixir.StreamJsonCore.Payload do
  @moduledoc """
  Shared interpretation of Claude-compatible `stream-json` payloads.

  Qoder CLI empirically emits the same event/result shape as Claude Code
  (`result`/`assistant`/`system`, UUID `session_id`, `usage` token fields,
  `permission_denials`), so the payload interpretation lives here once and is
  parameterized by the dialect for backend name, display name, and rate-limit
  extraction. Provider-specific flag construction and env markers stay in each
  backend dialect.
  """

  alias SymphonyElixir.AgentServer.{Approval, Error, Usage}
  alias SymphonyElixir.StreamJsonCore

  @transient_error_pattern ~r/(?:^|[^a-z0-9])(?:429|rate[_ -]?limit(?:ed)?|timeout|overload(?:ed)?|temporar(?:y|ily)|unavailable|connection(?:[_ -]?(?:reset|refused|closed|error))?|econnreset|econnrefused|too many requests)(?:$|[^a-z0-9])/

  @spec supported_payload?(map()) :: boolean()
  def supported_payload?(payload) when is_map(payload) do
    Map.get(payload, "type") in [
      "result",
      "error",
      "stream_event",
      "assistant",
      "user",
      "tool_use",
      "tool_result",
      "system"
    ]
  end

  @spec handle_payload(map(), String.t(), function(), map(), term(), module()) :: term()
  def handle_payload(_payload, _raw, _on_message, _metadata, {:error, %Error{}} = terminal_error, _dialect),
    do: terminal_error

  def handle_payload(%{"type" => "result"} = payload, raw, on_message, metadata, _result, dialect) do
    rate_limits = dialect.rate_limits(payload)

    cond do
      permission_denials(payload) != [] ->
        handle_permission_denial(payload, raw, on_message, metadata, rate_limits, dialect)

      Map.get(payload, "is_error") == true or error_result_subtype?(Map.get(payload, "subtype")) ->
        error = provider_error(payload)
        usage = failure_usage(payload, metadata, dialect)

        StreamJsonCore.emit(
          on_message,
          dialect.backend_name(),
          :turn_failed,
          Map.merge(metadata, %{error: error, usage: usage, rate_limits: rate_limits, payload: payload, raw: raw})
        )

        {:error, error}

      true ->
        case valid_provider_session_id(payload) do
          {:ok, provider_session_id} ->
            usage = usage(payload, provider_session_id, metadata.turn_id, dialect)

            StreamJsonCore.emit(
              on_message,
              dialect.backend_name(),
              :turn_completed,
              Map.merge(metadata, %{
                session_id: provider_session_id,
                usage: usage,
                rate_limits: rate_limits,
                payload: payload,
                raw: raw
              })
            )

            {:ok, provider_session_id, usage, payload}

          :error ->
            error =
              Error.new(:protocol, "#{dialect.display_name()} result event did not include a valid session_id",
                code: :invalid_session_id,
                retryable?: false,
                raw: payload
              )

            StreamJsonCore.emit(
              on_message,
              dialect.backend_name(),
              :malformed_protocol,
              Map.merge(metadata, %{
                error: error,
                usage: failure_usage(payload, metadata, dialect),
                rate_limits: rate_limits,
                payload: payload,
                raw: raw
              })
            )

            {:error, error}
        end
    end
  end

  def handle_payload(%{"type" => "error"} = payload, raw, on_message, metadata, _result, dialect) do
    error = provider_error(payload)
    usage = failure_usage(payload, metadata, dialect)

    StreamJsonCore.emit(
      on_message,
      dialect.backend_name(),
      :turn_failed,
      Map.merge(metadata, %{error: error, usage: usage, payload: payload, raw: raw})
    )

    {:error, error}
  end

  def handle_payload(%{"type" => "stream_event"} = payload, raw, on_message, metadata, result, dialect) do
    StreamJsonCore.emit(on_message, dialect.backend_name(), :progress, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  def handle_payload(%{"type" => "assistant"} = payload, raw, on_message, metadata, result, dialect) do
    type = if tool_activity?(payload), do: :tool_activity, else: :notification
    StreamJsonCore.emit(on_message, dialect.backend_name(), type, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  def handle_payload(%{"type" => type} = payload, raw, on_message, metadata, result, dialect)
      when type in ["user", "tool_use", "tool_result"] do
    StreamJsonCore.emit(on_message, dialect.backend_name(), :tool_activity, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  def handle_payload(payload, raw, on_message, metadata, result, dialect) do
    StreamJsonCore.emit(on_message, dialect.backend_name(), :notification, Map.merge(metadata, %{payload: payload, raw: raw}))
    result
  end

  defp handle_permission_denial(payload, raw, on_message, metadata, rate_limits, dialect) do
    denials = permission_denials(payload)

    approval =
      Approval.new(:tool, :required,
        request_id: {metadata.session_id, metadata.turn_id},
        auto_approved?: false,
        raw: denials
      )

    error =
      Error.new(:approval_required, "#{dialect.display_name()} requires tool approval",
        code: :permission_denied,
        retryable?: false,
        blocked?: true,
        raw: payload
      )

    usage = failure_usage(payload, metadata, dialect)

    StreamJsonCore.emit(
      on_message,
      dialect.backend_name(),
      :approval_required,
      Map.merge(metadata, %{
        approval: approval,
        error: error,
        usage: usage,
        rate_limits: rate_limits,
        payload: payload,
        raw: raw
      })
    )

    {:error, error}
  end

  defp permission_denials(payload) do
    case Map.get(payload, "permission_denials") do
      denials when is_list(denials) -> denials
      _ -> []
    end
  end

  defp error_result_subtype?(subtype) when is_binary(subtype), do: String.starts_with?(subtype, "error_")
  defp error_result_subtype?(_subtype), do: false

  defp provider_error(payload) do
    raw_error = Map.get(payload, "error") || payload
    message = provider_error_message(raw_error)
    code = provider_error_code(raw_error) || Map.get(payload, "subtype") || :provider_error
    retryable? = transient_provider_error?(code, message)

    Error.new(:provider, message, code: code, retryable?: retryable?, raw: payload)
  end

  defp provider_error_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_error_message(message) when is_binary(message), do: message
  defp provider_error_message(error), do: inspect(error)

  defp provider_error_code(%{"type" => type}) when is_binary(type), do: type
  defp provider_error_code(%{"code" => code}), do: code
  defp provider_error_code(_error), do: nil

  defp transient_provider_error?(code, message) do
    text = String.downcase("#{code} #{message}")
    Regex.match?(@transient_error_pattern, text)
  end

  @spec usage(map(), String.t(), String.t(), module()) :: Usage.t()
  def usage(payload, session_id, turn_id, dialect) do
    raw = Map.get(payload, "usage") || %{}

    Usage.delta(
      :turn,
      non_negative_integer(Map.get(raw, "input_tokens")),
      non_negative_integer(Map.get(raw, "output_tokens")),
      {dialect.usage_identity_tag(), session_id, turn_id},
      total_tokens: non_negative_integer(Map.get(raw, "total_tokens")),
      cache_read_input_tokens: non_negative_integer(Map.get(raw, "cache_read_input_tokens")),
      cache_creation_input_tokens: non_negative_integer(Map.get(raw, "cache_creation_input_tokens")),
      raw: raw
    )
  end

  @spec failure_usage(map(), map(), module()) :: Usage.t()
  def failure_usage(payload, metadata, dialect) do
    session_id =
      case valid_provider_session_id(payload) do
        {:ok, provider_session_id} -> provider_session_id
        :error -> metadata.session_id
      end

    usage(payload, session_id, metadata.turn_id, dialect)
  end

  @spec valid_provider_session_id(map()) :: {:ok, String.t()} | :error
  def valid_provider_session_id(payload) do
    case Map.get(payload, "session_id") do
      session_id when is_binary(session_id) ->
        trimmed = String.trim(session_id)

        if String.match?(
             trimmed,
             ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/
           ) do
          {:ok, trimmed}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp tool_activity?(payload) do
    payload
    |> get_in(["message", "content"])
    |> case do
      content when is_list(content) -> Enum.any?(content, &(is_map(&1) and Map.get(&1, "type") == "tool_use"))
      _ -> false
    end
  end
end
