defmodule WaggerWeb.McpDownloadControllerTest do
  @moduledoc false
  use WaggerWeb.ConnCase

  @salt "mcp-download"

  test "valid token returns YANG body with attachment header", %{conn: conn} do
    payload = %{yang_text: "module x {}", filename: "x-mcp.yang"}
    token = Phoenix.Token.sign(WaggerWeb.Endpoint, @salt, payload)

    conn = get(conn, ~p"/mcp/download/#{token}")
    assert conn.status == 200
    assert response(conn, 200) == "module x {}"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/yang"
    assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment; filename=\"x-mcp.yang\""
  end

  test "expired token returns 410", %{conn: conn} do
    payload = %{yang_text: "x", filename: "x.yang"}
    token = Phoenix.Token.sign(WaggerWeb.Endpoint, @salt, payload, signed_at: 0)

    conn = get(conn, ~p"/mcp/download/#{token}")
    assert conn.status == 410
  end

  test "garbage token returns 403", %{conn: conn} do
    conn = get(conn, ~p"/mcp/download/garbage")
    assert conn.status == 403
  end
end
