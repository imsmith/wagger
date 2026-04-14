defmodule WaggerWeb.Plugs.Authenticate do
  @moduledoc """
  Plug that authenticates requests via Bearer API key.

  Extracts a Bearer token from the Authorization header and validates it
  against the stored API key hash via `Wagger.Accounts.authenticate_by_api_key/1`.

  On success, assigns `current_user` to the conn and proceeds.

  On failure or missing header:
  - If `allow_setup: true` is passed as an option AND no users exist
    (`Accounts.setup_required?/0` returns true), assigns `setup_mode: true`
    and proceeds without authentication.
  - Otherwise, responds with 401 JSON and halts the pipeline.
  """

  import Plug.Conn

  alias Wagger.Accounts

  def init(opts), do: opts

  def call(conn, opts) do
    case get_bearer_token(conn) do
      {:ok, token} ->
        authenticate_token(conn, token)

      :missing ->
        handle_missing_auth(conn, opts)
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> :missing
    end
  end

  defp authenticate_token(conn, token) do
    case Accounts.authenticate_by_api_key(token) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :error ->
        halt_unauthorized(conn)
    end
  end

  defp handle_missing_auth(conn, opts) do
    allow_setup = Keyword.get(opts, :allow_setup, false)

    if allow_setup and Accounts.setup_required?() do
      assign(conn, :setup_mode, true)
    else
      halt_unauthorized(conn)
    end
  end

  defp halt_unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
