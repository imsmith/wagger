defmodule Wagger.Import.BulkTest do
  @moduledoc """
  Tests for Wagger.Import.Bulk — the bulk text route parser.

  Covers all supported input formats, normalization, inference, and error
  handling described in the import pipeline specification.
  """

  use ExUnit.Case, async: true

  alias Wagger.Import.Bulk

  describe "parse/1 — method parsing" do
    test "parses METHOD /path format" do
      {routes, skipped} = Bulk.parse("GET /users")

      assert skipped == []
      assert length(routes) == 1
      assert hd(routes).path == "/users"
      assert hd(routes).methods == ["GET"]
    end

    test "parses multiple comma-separated methods with description" do
      {routes, skipped} = Bulk.parse("GET,POST /api/items - list and create items")

      assert skipped == []
      assert length(routes) == 1
      route = hd(routes)
      assert route.methods == ["GET", "POST"]
      assert route.description == "list and create items"
    end

    test "defaults to GET when no method given" do
      {routes, skipped} = Bulk.parse("/health")

      assert skipped == []
      assert length(routes) == 1
      assert hd(routes).methods == ["GET"]
    end

    test "normalizes methods to uppercase" do
      {routes, _skipped} = Bulk.parse("get,post /api/things")

      assert hd(routes).methods == ["GET", "POST"]
    end
  end

  describe "parse/1 — path normalization" do
    test "converts Express :param to {param}" do
      {routes, _skipped} = Bulk.parse("GET /users/:id")

      assert hd(routes).path == "/users/{id}"
    end

    test "converts multiple Express params" do
      {routes, _skipped} = Bulk.parse("GET /orgs/:org/repos/:repo")

      assert hd(routes).path == "/orgs/{org}/repos/{repo}"
    end
  end

  describe "parse/1 — path_type inference" do
    test "infers prefix for trailing slash path" do
      {routes, _skipped} = Bulk.parse("GET /api/v1/")

      assert hd(routes).path_type == "prefix"
    end

    test "infers exact for non-trailing-slash path" do
      {routes, _skipped} = Bulk.parse("GET /users")

      assert hd(routes).path_type == "exact"
    end

    test "root / is exact, not prefix" do
      {routes, _skipped} = Bulk.parse("/")

      assert hd(routes).path_type == "exact"
    end
  end

  describe "parse/1 — skipping" do
    test "skips comment lines" do
      input = """
      # this is a comment
      GET /users
      """

      {routes, skipped} = Bulk.parse(input)

      assert length(routes) == 1
      assert skipped == []
    end

    test "skips blank lines" do
      input = """
      GET /users

      POST /items
      """

      {routes, skipped} = Bulk.parse(input)

      assert length(routes) == 2
      assert skipped == []
    end

    test "reports unparseable lines as skipped with line numbers" do
      input = """
      GET /users
      ??? not a route at all ??? !@@#
      POST /items
      """

      {routes, skipped} = Bulk.parse(input)

      assert length(routes) == 2
      assert length(skipped) == 1
      assert hd(skipped) == "line 2: ??? not a route at all ??? !@@#"
    end
  end

  describe "parse/1 — multi-route" do
    test "handles multiple routes in one pass" do
      input = """
      GET /users - list users
      POST /users - create user
      GET /users/:id - get user
      DELETE /users/:id - delete user
      """

      {routes, skipped} = Bulk.parse(input)

      assert skipped == []
      assert length(routes) == 4

      paths = Enum.map(routes, & &1.path)
      assert "/users" in paths
      assert "/users/{id}" in paths
    end

    test "description is nil when not provided" do
      {routes, _skipped} = Bulk.parse("GET /ping")

      assert hd(routes).description == nil
    end
  end
end
