defmodule WaggerWeb.McpDownloadController do
  @moduledoc """
  Serves a one-shot download for a `Phoenix.Token`-signed payload of
  `%{yang_text, filename}`. Tokens expire after 5 minutes (signed at issue time).
  """

  use WaggerWeb, :controller

  @salt "mcp-download"
  @max_age 300

  def show(conn, %{"token" => token}) do
    case Phoenix.Token.verify(WaggerWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{yang_text: yang_text, filename: filename}} ->
        conn
        |> put_resp_content_type("application/yang")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, yang_text)

      {:error, :expired} ->
        send_resp(conn, 410, "expired")

      {:error, _} ->
        send_resp(conn, 403, "forbidden")
    end
  end
end
