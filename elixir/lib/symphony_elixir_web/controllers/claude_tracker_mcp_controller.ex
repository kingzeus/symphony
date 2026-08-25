defmodule SymphonyElixirWeb.ClaudeTrackerMCPController do
  @moduledoc """
  Authenticated Streamable HTTP endpoint for Claude Code tracker tools.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ClaudeTrackerMCP

  @spec handle(Conn.t(), map()) :: Conn.t()
  def handle(conn, request) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, capability} <- ClaudeTrackerMCP.lookup(token) do
      case ClaudeTrackerMCP.handle_request(capability, request) do
        {:ok, response} -> json(conn, response)
        :accepted -> send_resp(conn, 202, "")
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _other -> {:error, :unauthorized}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: %{code: "unauthorized", message: "Unauthorized"}})
  end
end
