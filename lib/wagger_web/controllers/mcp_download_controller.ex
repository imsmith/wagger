defmodule WaggerWeb.McpDownloadController do
  @moduledoc """
  Serves a download for a `Phoenix.Token`-signed payload of
  `%{yang_text, filename}` issued by `WaggerWeb.McpGeneratorLive`.

  The route sits behind `WaggerWeb.Plugs.RequireUser`, so only a signed-in
  browser can redeem a token. Tokens are stateless and expire 5 minutes after
  issue; within that window the same URL may be followed more than once. They
  are not single-use — making them so would need server-side redemption state,
  which the paste-and-download flow has no call for.
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
