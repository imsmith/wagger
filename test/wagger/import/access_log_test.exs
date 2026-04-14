defmodule Wagger.Import.AccessLogTest do
  @moduledoc """
  Tests for Wagger.Import.AccessLog — the web server access log parser.

  Covers nginx combined/common, Caddy JSON, Apache combined formats,
  query string stripping, method grouping, sorting, and skip handling.
  """

  use ExUnit.Case, async: true

  alias Wagger.Import.AccessLog

  describe "parse/1 — nginx combined format" do
    test "extracts path and method from nginx combined format" do
      line =
        ~s(192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl/7.68")

      {routes, skipped} = AccessLog.parse(line)

      assert skipped == []
      assert length(routes) == 1
      route = hd(routes)
      assert route.path == "/api/users"
      assert route.methods == ["GET"]
    end

    test "strips query strings from paths" do
      line =
        ~s(192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users?page=1&limit=10 HTTP/1.1" 200 612 "-" "curl/7.68")

      {routes, _skipped} = AccessLog.parse(line)

      assert hd(routes).path == "/api/users"
    end

    test "groups by path and collects distinct methods" do
      input = """
      192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/items HTTP/1.1" 200 100 "-" "-"
      192.168.1.2 - - [10/Apr/2026:13:55:37 +0000] "POST /api/items HTTP/1.1" 201 50 "-" "-"
      """

      {routes, skipped} = AccessLog.parse(input)

      assert skipped == []
      assert length(routes) == 1
      route = hd(routes)
      assert route.path == "/api/items"
      assert Enum.sort(route.methods) == ["GET", "POST"]
    end

    test "includes request count in description" do
      input = """
      192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/items HTTP/1.1" 200 100 "-" "-"
      192.168.1.2 - - [10/Apr/2026:13:55:37 +0000] "POST /api/items HTTP/1.1" 201 50 "-" "-"
      """

      {routes, _skipped} = AccessLog.parse(input)

      assert hd(routes).description == "2 request(s) observed"
    end

    test "1 request uses singular-compatible description" do
      line =
        ~s(192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "-")

      {routes, _skipped} = AccessLog.parse(line)

      assert hd(routes).description == "1 request(s) observed"
    end

    test "sorts by request count descending" do
      input = """
      192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /a HTTP/1.1" 200 100 "-" "-"
      192.168.1.1 - - [10/Apr/2026:13:55:37 +0000] "GET /b HTTP/1.1" 200 100 "-" "-"
      192.168.1.1 - - [10/Apr/2026:13:55:38 +0000] "GET /b HTTP/1.1" 200 100 "-" "-"
      192.168.1.1 - - [10/Apr/2026:13:55:39 +0000] "GET /b HTTP/1.1" 200 100 "-" "-"
      """

      {routes, _skipped} = AccessLog.parse(input)

      assert length(routes) == 2
      assert hd(routes).path == "/b"
      assert List.last(routes).path == "/a"
    end

    test "all parsed routes have exact path_type" do
      line =
        ~s(192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "-")

      {routes, _skipped} = AccessLog.parse(line)

      assert hd(routes).path_type == "exact"
    end
  end

  describe "parse/1 — Caddy JSON format" do
    test "parses Caddy JSON log lines" do
      line = ~s({"request":{"method":"GET","uri":"/api/users?page=1"},"status":200})

      {routes, skipped} = AccessLog.parse(line)

      assert skipped == []
      assert length(routes) == 1
      route = hd(routes)
      assert route.path == "/api/users"
      assert route.methods == ["GET"]
    end

    test "Caddy JSON result has exact path_type" do
      line = ~s({"request":{"method":"POST","uri":"/api/items"},"status":201})

      {routes, _skipped} = AccessLog.parse(line)

      assert hd(routes).path_type == "exact"
    end
  end

  describe "parse/1 — Apache combined format" do
    test "parses Apache combined log format" do
      line =
        ~s(10.0.0.1 - frank [10/Apr/2026:13:55:36 -0700] "DELETE /api/resource HTTP/1.0" 204 0)

      {routes, skipped} = AccessLog.parse(line)

      assert skipped == []
      assert length(routes) == 1
      route = hd(routes)
      assert route.path == "/api/resource"
      assert route.methods == ["DELETE"]
    end
  end

  describe "parse/1 — skip handling" do
    test "skips unparseable lines with line number prefix" do
      input = """
      192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "-"
      this is not a log line at all
      192.168.1.1 - - [10/Apr/2026:13:55:38 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "-"
      """

      {routes, skipped} = AccessLog.parse(input)

      assert length(routes) == 2
      assert length(skipped) == 1
      assert hd(skipped) == "line 2: this is not a log line at all"
    end

    test "skips truncates long unparseable lines at 80 chars" do
      bad_line = String.duplicate("x", 100)

      {_routes, skipped} = AccessLog.parse(bad_line)

      assert length(skipped) == 1
      assert hd(skipped) == "line 1: #{String.slice(bad_line, 0, 80)}"
    end

    test "blank lines are silently skipped, not counted as skipped" do
      input = """
      192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "-"

      192.168.1.1 - - [10/Apr/2026:13:55:38 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "-"
      """

      {routes, skipped} = AccessLog.parse(input)

      assert length(routes) == 2
      assert skipped == []
    end
  end
end
