defmodule WaggerWeb.McpGeneratorLiveTest do
  @moduledoc false
  use WaggerWeb.ConnCase
  import Phoenix.LiveViewTest

  @valid_yang """
  module demo {
    yang-version 1.1;
    namespace "urn:demo";
    prefix demo;
    revision 2026-04-27 { description "x"; }
    rpc create-note { description "Save a note."; }
    list notes { key id; leaf id { type string; } }
  }
  """

  test "mount renders textarea and submit button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mcp")
    assert html =~ "MCP Generator"
    assert html =~ ~s(name="yang_source")
    assert html =~ "Generate"
    refute html =~ "Derivation report"
  end

  test "submit valid YANG renders report and download link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    html =
      view
      |> form("#mcp-form", %{"yang_source" => @valid_yang})
      |> render_submit()

    assert html =~ "Derivation report"
    assert html =~ "1 tool"
    assert html =~ "1 resource"
    assert html =~ "create_note"
    assert html =~ "/mcp/download/"
  end

  test "submit invalid YANG renders error card without download link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    html =
      view
      |> form("#mcp-form", %{"yang_source" => "garbage"})
      |> render_submit()

    assert html =~ "wagger.generator/yang_parse_failed"
    refute html =~ "/mcp/download/"
  end
end
