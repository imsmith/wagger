# Import Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three import paths (bulk text, OpenAPI JSON, access logs) that parse external route data into a preview, detect conflicts with existing routes, and commit confirmed imports to the database.

**Architecture:** Each importer is a pure parser module that takes raw input and returns a list of route maps. A shared Preview module handles conflict detection against existing routes and HMAC token generation. The ImportController dispatches to the appropriate parser and orchestrates the two-step preview/confirm flow.

**Tech Stack:** Elixir, Phoenix, Ecto, Jason (for OpenAPI JSON parsing). No new dependencies.

---

## File Structure

```
lib/wagger/import/
  bulk.ex               — bulk text parser (METHOD /path - description)
  openapi.ex            — OpenAPI 3.x JSON parser
  access_log.ex         — access log parser (nginx, apache, caddy, ALB)
  preview.ex            — conflict detection, HMAC token, confirm logic
lib/wagger_web/controllers/
  import_controller.ex  — handles all 4 import endpoints
  import_json.ex        — JSON view for preview responses
test/wagger/import/
  bulk_test.exs
  openapi_test.exs
  access_log_test.exs
  preview_test.exs
test/wagger_web/controllers/
  import_controller_test.exs
```

All parsers share the same return type: a list of maps matching the Route schema fields (`path`, `methods`, `path_type`, `description`, `query_params`, `headers`, `rate_limit`, `tags`), plus a `skipped` list of unparseable lines.

---

### Task 1: Bulk Text Parser

**Files:**
- Create: `lib/wagger/import/bulk.ex`
- Test: `test/wagger/import/bulk_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/import/bulk_test.exs
defmodule Wagger.Import.BulkTest do
  use ExUnit.Case, async: true

  alias Wagger.Import.Bulk

  describe "parse/1" do
    test "parses METHOD /path format" do
      input = "GET /api/users"
      assert {[%{path: "/api/users", methods: ["GET"]}], []} = Bulk.parse(input)
    end

    test "parses multiple methods" do
      input = "GET,POST /api/items - Item CRUD"
      {[route], []} = Bulk.parse(input)
      assert route.path == "/api/items"
      assert route.methods == ["GET", "POST"]
      assert route.description == "Item CRUD"
    end

    test "defaults to GET when no method specified" do
      input = "/health"
      {[route], []} = Bulk.parse(input)
      assert route.methods == ["GET"]
    end

    test "normalizes Express :param to {param}" do
      input = "GET /api/users/:id/posts/:post_id"
      {[route], []} = Bulk.parse(input)
      assert route.path == "/api/users/{id}/posts/{post_id}"
    end

    test "infers prefix path_type for paths ending in /" do
      input = "GET /static/"
      {[route], []} = Bulk.parse(input)
      assert route.path_type == "prefix"
    end

    test "uses exact path_type for non-trailing-slash paths" do
      input = "GET /api/users"
      {[route], []} = Bulk.parse(input)
      assert route.path_type == "exact"
    end

    test "root path / is exact, not prefix" do
      input = "GET /"
      {[route], []} = Bulk.parse(input)
      assert route.path_type == "exact"
    end

    test "skips comment lines" do
      input = "# This is a comment\nGET /api/users"
      {routes, []} = Bulk.parse(input)
      assert length(routes) == 1
    end

    test "skips blank lines" do
      input = "\nGET /api/users\n\n"
      {routes, []} = Bulk.parse(input)
      assert length(routes) == 1
    end

    test "reports unparseable lines as skipped" do
      input = "GET /api/users\nnot a valid line here\nPOST /api/items"
      {routes, skipped} = Bulk.parse(input)
      assert length(routes) == 2
      assert ["line 2: not a valid line here"] = skipped
    end

    test "handles multiple routes" do
      input = """
      GET /api/v1/users
      GET,POST /api/v1/items - Item CRUD
      DELETE /api/v1/items/{id}
      /health
      """
      {routes, []} = Bulk.parse(input)
      assert length(routes) == 4
    end

    test "handles case-insensitive methods" do
      input = "get,post /api/users"
      {[route], []} = Bulk.parse(input)
      assert route.methods == ["GET", "POST"]
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/import/bulk_test.exs
```

Expected: compilation error, module not found.

- [ ] **Step 3: Implement Bulk parser**

```elixir
# lib/wagger/import/bulk.ex
defmodule Wagger.Import.Bulk do
  @moduledoc """
  Parses bulk text route definitions into route maps.

  Accepts the format: `METHOD /path - description`, one per line.
  Methods are comma-separated. Lines starting with `#` are comments.
  Express-style `:param` placeholders are normalized to `{param}`.
  """

  @http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  @method_pattern Enum.join(@http_methods, "|")
  @line_regex ~r/^(?:((?:#{@method_pattern})(?:\s*,\s*(?:#{@method_pattern}))*)?\s+)?(\S+)(?:\s+-\s+(.*))?$/i

  @doc """
  Parses bulk text input into a list of route maps and skipped lines.

  Returns `{routes, skipped}` where routes is a list of maps with keys
  `:path`, `:methods`, `:path_type`, `:description`, and skipped is a list
  of strings like `"line N: original text"`.
  """
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_num}, {routes, skipped} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" -> {routes, skipped}
        String.starts_with?(trimmed, "#") -> {routes, skipped}
        true ->
          case parse_line(trimmed) do
            {:ok, route} -> {routes ++ [route], skipped}
            :skip -> {routes, skipped ++ ["line #{line_num}: #{trimmed}"]}
          end
      end
    end)
  end

  defp parse_line(line) do
    case Regex.run(@line_regex, line) do
      [_, methods_str, path | rest] ->
        methods = parse_methods(methods_str)
        description = List.first(rest, "")
        normalized_path = normalize_path(path)

        path_type =
          if String.ends_with?(normalized_path, "/") and normalized_path != "/" do
            "prefix"
          else
            "exact"
          end

        {:ok, %{
          path: normalized_path,
          methods: methods,
          path_type: path_type,
          description: if(description == "", do: nil, else: description)
        }}

      _ ->
        :skip
    end
  end

  defp parse_methods(""), do: ["GET"]
  defp parse_methods(nil), do: ["GET"]

  defp parse_methods(methods_str) do
    methods_str
    |> String.split(~r/\s*,\s*/)
    |> Enum.map(&String.upcase/1)
  end

  defp normalize_path(path) do
    String.replace(path, ~r/:(\w+)/, "{\\1}")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/import/bulk_test.exs
```

Expected: 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/import/bulk.ex test/wagger/import/bulk_test.exs
git commit -m "Add bulk text route parser for import pipeline"
```

---

### Task 2: OpenAPI JSON Parser

**Files:**
- Create: `lib/wagger/import/openapi.ex`
- Test: `test/wagger/import/openapi_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/import/openapi_test.exs
defmodule Wagger.Import.OpenApiTest do
  use ExUnit.Case, async: true

  alias Wagger.Import.OpenApi

  @minimal_spec %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "Test", "version" => "1.0"},
    "paths" => %{
      "/api/users" => %{
        "get" => %{
          "summary" => "List users",
          "parameters" => [
            %{"name" => "page", "in" => "query", "required" => false},
            %{"name" => "Authorization", "in" => "header", "required" => true}
          ]
        },
        "post" => %{
          "summary" => "Create user"
        }
      },
      "/api/users/{id}" => %{
        "get" => %{"summary" => "Get user"},
        "put" => %{"summary" => "Update user"},
        "delete" => %{"summary" => "Delete user"}
      }
    }
  }

  describe "parse/1" do
    test "extracts paths and methods from spec" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      assert length(routes) == 2

      users = Enum.find(routes, &(&1.path == "/api/users"))
      assert Enum.sort(users.methods) == ["GET", "POST"]
    end

    test "extracts description from first operation summary" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      users = Enum.find(routes, &(&1.path == "/api/users"))
      assert users.description == "List users"
    end

    test "extracts query parameters" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      users = Enum.find(routes, &(&1.path == "/api/users"))
      assert [%{"name" => "page", "required" => false}] = users.query_params
    end

    test "extracts header parameters" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      users = Enum.find(routes, &(&1.path == "/api/users"))
      assert [%{"name" => "Authorization", "required" => true}] = users.headers
    end

    test "preserves {param} path format" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      user = Enum.find(routes, &(String.contains?(&1.path, "{id}")))
      assert user.path == "/api/users/{id}"
    end

    test "all routes are exact path_type" do
      {routes, []} = OpenApi.parse(@minimal_spec)
      assert Enum.all?(routes, &(&1.path_type == "exact"))
    end

    test "accepts JSON string input" do
      json = Jason.encode!(@minimal_spec)
      {routes, []} = OpenApi.parse(json)
      assert length(routes) == 2
    end

    test "returns error for invalid JSON string" do
      assert {[], ["Invalid JSON: " <> _]} = OpenApi.parse("not json")
    end

    test "returns error for missing paths key" do
      spec = %{"openapi" => "3.0.0", "info" => %{}}
      assert {[], ["No paths found in OpenAPI spec"]} = OpenApi.parse(spec)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/import/openapi_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement OpenApi parser**

```elixir
# lib/wagger/import/openapi.ex
defmodule Wagger.Import.OpenApi do
  @moduledoc """
  Parses OpenAPI 3.x JSON specifications into route maps.

  Extracts paths, HTTP methods, summaries/descriptions, and parameter
  definitions. Path parameters are already in `{param}` format per the
  OpenAPI convention. Query and header parameters are extracted and
  categorized.
  """

  @http_methods ~w(get post put patch delete head options)

  @doc """
  Parses an OpenAPI spec (map or JSON string) into route maps and errors.

  Returns `{routes, errors}` where routes is a list of maps with keys
  `:path`, `:methods`, `:path_type`, `:description`, `:query_params`, `:headers`.
  """
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, spec} -> parse(spec)
      {:error, %Jason.DecodeError{} = err} -> {[], ["Invalid JSON: #{Exception.message(err)}"]}
    end
  end

  def parse(%{"paths" => paths}) when is_map(paths) do
    routes =
      Enum.map(paths, fn {path, operations} ->
        methods = extract_methods(operations)
        description = extract_description(operations)
        {query_params, headers} = extract_parameters(operations)

        %{
          path: path,
          methods: methods,
          path_type: "exact",
          description: description,
          query_params: query_params,
          headers: headers
        }
      end)

    {routes, []}
  end

  def parse(%{} = _spec), do: {[], ["No paths found in OpenAPI spec"]}

  defp extract_methods(operations) do
    operations
    |> Map.keys()
    |> Enum.filter(&(&1 in @http_methods))
    |> Enum.map(&String.upcase/1)
  end

  defp extract_description(operations) do
    operations
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(fn op ->
      Map.get(op, "summary") || Map.get(op, "description")
    end)
  end

  defp extract_parameters(operations) do
    all_params =
      operations
      |> Map.values()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&Map.get(&1, "parameters", []))
      |> Enum.uniq_by(&Map.get(&1, "name"))

    query_params =
      all_params
      |> Enum.filter(&(Map.get(&1, "in") == "query"))
      |> Enum.map(&%{"name" => &1["name"], "required" => &1["required"] || false})

    headers =
      all_params
      |> Enum.filter(&(Map.get(&1, "in") == "header"))
      |> Enum.map(&%{"name" => &1["name"], "required" => &1["required"] || false})

    {query_params, headers}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/import/openapi_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/import/openapi.ex test/wagger/import/openapi_test.exs
git commit -m "Add OpenAPI 3.x JSON parser for import pipeline"
```

---

### Task 3: Access Log Parser

**Files:**
- Create: `lib/wagger/import/access_log.ex`
- Test: `test/wagger/import/access_log_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/import/access_log_test.exs
defmodule Wagger.Import.AccessLogTest do
  use ExUnit.Case, async: true

  alias Wagger.Import.AccessLog

  describe "parse/1 with nginx combined format" do
    test "extracts path and method" do
      log = ~s(192.168.1.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl/7.68")
      {routes, []} = AccessLog.parse(log)
      assert [%{path: "/api/users", methods: ["GET"]}] = routes
    end

    test "strips query strings" do
      log = ~s(10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users?page=1&limit=10 HTTP/1.1" 200 612 "-" "curl")
      {[route], []} = AccessLog.parse(log)
      assert route.path == "/api/users"
    end

    test "groups by path and collects methods" do
      log = """
      10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl"
      10.0.0.1 - - [10/Apr/2026:13:55:37 +0000] "POST /api/users HTTP/1.1" 201 100 "-" "curl"
      10.0.0.1 - - [10/Apr/2026:13:55:38 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl"
      """
      {routes, []} = AccessLog.parse(log)
      route = Enum.find(routes, &(&1.path == "/api/users"))
      assert Enum.sort(route.methods) == ["GET", "POST"]
    end

    test "includes request count in description" do
      log = """
      10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl"
      10.0.0.2 - - [10/Apr/2026:13:55:37 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl"
      10.0.0.1 - - [10/Apr/2026:13:55:38 +0000] "GET /api/items HTTP/1.1" 200 100 "-" "curl"
      """
      {routes, []} = AccessLog.parse(log)
      users = Enum.find(routes, &(&1.path == "/api/users"))
      assert users.description =~ "2 requests"
    end

    test "sorts by request count descending" do
      log = """
      10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /rare HTTP/1.1" 200 100 "-" "curl"
      10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /popular HTTP/1.1" 200 100 "-" "curl"
      10.0.0.2 - - [10/Apr/2026:13:55:36 +0000] "GET /popular HTTP/1.1" 200 100 "-" "curl"
      10.0.0.3 - - [10/Apr/2026:13:55:36 +0000] "GET /popular HTTP/1.1" 200 100 "-" "curl"
      """
      {routes, []} = AccessLog.parse(log)
      assert hd(routes).path == "/popular"
    end
  end

  describe "parse/1 with caddy JSON format" do
    test "extracts path and method from JSON lines" do
      log = ~s({"request":{"method":"GET","uri":"/api/users?page=1"},"status":200})
      {[route], []} = AccessLog.parse(log)
      assert route.path == "/api/users"
      assert route.methods == ["GET"]
    end
  end

  describe "parse/1 with apache format" do
    test "extracts path and method" do
      log = ~s(192.168.1.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache.gif HTTP/1.0" 200 2326)
      {[route], []} = AccessLog.parse(log)
      assert route.path == "/apache.gif"
      assert route.methods == ["GET"]
    end
  end

  describe "parse/1 with mixed/unknown formats" do
    test "skips unparseable lines" do
      log = """
      garbage data here
      10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl"
      more garbage
      """
      {routes, skipped} = AccessLog.parse(log)
      assert length(routes) == 1
      assert length(skipped) == 2
    end
  end

  describe "parse/1 with all path_type values" do
    test "all parsed routes default to exact" do
      log = ~s(10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl")
      {[route], []} = AccessLog.parse(log)
      assert route.path_type == "exact"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/import/access_log_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement AccessLog parser**

```elixir
# lib/wagger/import/access_log.ex
defmodule Wagger.Import.AccessLog do
  @moduledoc """
  Parses access log files into route maps.

  Supports multiple log formats through auto-detection:
  - Nginx/Apache combined/common log format
  - Caddy JSON log format
  - AWS ALB log format

  Extracts unique paths (stripped of query strings), groups by observed HTTP
  methods, ranks by request count, and defaults all routes to exact path_type.
  """

  # Matches: "METHOD /path HTTP/x.x" in nginx/apache combined/common format
  @nginx_regex ~r/"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)\s+HTTP\/[\d.]+"/i

  # Matches ALB format: METHOD https?://host:port/path HTTP/x.x
  @alb_regex ~r/"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+https?://[^/]+(\S+)\s+HTTP\/[\d.]+"/i

  @doc """
  Parses access log text into route maps sorted by request count (descending).

  Returns `{routes, skipped}` where routes is a list of maps with keys
  `:path`, `:methods`, `:path_type`, `:description`, and skipped is a list
  of unparseable line descriptions.
  """
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {parsed, skipped} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, line_num}, {parsed_acc, skipped_acc} ->
        case parse_line(line) do
          {:ok, method, path} -> {[{method, path} | parsed_acc], skipped_acc}
          :skip -> {parsed_acc, ["line #{line_num}: #{String.slice(line, 0, 80)}" | skipped_acc]}
        end
      end)

    routes =
      parsed
      |> Enum.group_by(fn {_method, path} -> path end)
      |> Enum.map(fn {path, entries} ->
        methods = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
        count = length(entries)

        %{
          path: path,
          methods: methods,
          path_type: "exact",
          description: "#{count} request#{if count == 1, do: "", else: "s"} observed"
        }
      end)
      |> Enum.sort_by(& &1.description, :desc)

    {routes, Enum.reverse(skipped)}
  end

  defp parse_line(line) do
    cond do
      # Try Caddy JSON format first
      String.starts_with?(line, "{") -> parse_caddy_json(line)
      # Try nginx/apache combined format
      match = Regex.run(@nginx_regex, line) -> parse_nginx_match(match)
      # Try ALB format
      match = Regex.run(@alb_regex, line) -> parse_nginx_match(match)
      true -> :skip
    end
  end

  defp parse_caddy_json(line) do
    case Jason.decode(line) do
      {:ok, %{"request" => %{"method" => method, "uri" => uri}}} ->
        {:ok, String.upcase(method), strip_query(uri)}

      _ ->
        :skip
    end
  end

  defp parse_nginx_match([_, method, path]) do
    {:ok, String.upcase(method), strip_query(path)}
  end

  defp strip_query(path) do
    path |> String.split("?") |> hd()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/import/access_log_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/import/access_log.ex test/wagger/import/access_log_test.exs
git commit -m "Add access log parser with nginx, caddy, and ALB support"
```

---

### Task 4: Preview Module (Conflict Detection + HMAC)

**Files:**
- Create: `lib/wagger/import/preview.ex`
- Test: `test/wagger/import/preview_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/import/preview_test.exs
defmodule Wagger.Import.PreviewTest do
  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Import.Preview

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET"], path_type: "exact"})
    %{app: app}
  end

  describe "build/2" do
    test "returns parsed routes and empty conflicts when no overlap", %{app: app} do
      incoming = [%{path: "/api/items", methods: ["GET"], path_type: "exact"}]
      preview = Preview.build(app, incoming)
      assert length(preview.parsed) == 1
      assert preview.conflicts == []
      assert is_binary(preview.preview_token)
    end

    test "detects conflicts with existing routes", %{app: app} do
      incoming = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/api/items", methods: ["GET"], path_type: "exact"}
      ]
      preview = Preview.build(app, incoming)
      assert length(preview.parsed) == 2
      assert length(preview.conflicts) == 1
      conflict = hd(preview.conflicts)
      assert conflict.path == "/api/users"
      assert conflict.existing.methods == ["GET"]
      assert conflict.incoming.methods == ["GET", "POST"]
    end

    test "preview_token is an HMAC of parsed routes" do
      {:ok, app2} = Applications.create_application(%{name: "app2"})
      incoming = [%{path: "/test", methods: ["GET"], path_type: "exact"}]
      p1 = Preview.build(app2, incoming)
      p2 = Preview.build(app2, incoming)
      assert p1.preview_token == p2.preview_token
    end
  end

  describe "verify_token/2" do
    test "returns true for valid token" do
      {:ok, app2} = Applications.create_application(%{name: "app2"})
      incoming = [%{path: "/test", methods: ["GET"], path_type: "exact"}]
      preview = Preview.build(app2, incoming)
      assert Preview.verify_token(preview.parsed, preview.preview_token)
    end

    test "returns false for tampered routes" do
      {:ok, app2} = Applications.create_application(%{name: "app2"})
      incoming = [%{path: "/test", methods: ["GET"], path_type: "exact"}]
      preview = Preview.build(app2, incoming)
      tampered = [%{path: "/hacked", methods: ["GET"], path_type: "exact"}]
      refute Preview.verify_token(tampered, preview.preview_token)
    end
  end

  describe "confirm/2" do
    test "inserts all non-conflicting routes", %{app: app} do
      incoming = [
        %{path: "/api/items", methods: ["GET"], path_type: "exact"},
        %{path: "/api/posts", methods: ["POST"], path_type: "exact"}
      ]
      preview = Preview.build(app, incoming)
      assert {:ok, inserted} = Preview.confirm(app, preview)
      assert length(inserted) == 2
      assert length(Routes.list_routes(app)) == 3
    end

    test "skips routes that conflict (does not update existing)", %{app: app} do
      incoming = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/api/items", methods: ["GET"], path_type: "exact"}
      ]
      preview = Preview.build(app, incoming)
      assert {:ok, inserted} = Preview.confirm(app, preview)
      assert length(inserted) == 1
      assert hd(inserted).path == "/api/items"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/import/preview_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement Preview module**

```elixir
# lib/wagger/import/preview.ex
defmodule Wagger.Import.Preview do
  @moduledoc """
  Handles the preview/confirm flow for route imports.

  Builds a preview by comparing incoming parsed routes against existing routes
  in the database, detecting conflicts, and generating an HMAC token for
  tamper-proof confirmation. The confirm step inserts non-conflicting routes.
  """

  alias Wagger.Routes
  alias Wagger.Applications.Application

  defstruct [:parsed, :conflicts, :skipped, :preview_token]

  @hmac_secret Elixir.Application.compile_env(:wagger, :import_hmac_secret, "wagger-import-default-secret")

  @doc """
  Builds a preview comparing incoming routes against existing routes for the app.

  Returns a `%Preview{}` with:
  - `parsed` — the incoming routes as maps
  - `conflicts` — routes that already exist (with both existing and incoming data)
  - `preview_token` — HMAC of the parsed routes for tamper verification
  """
  def build(%Application{} = app, incoming_routes, skipped \\ []) do
    existing = Routes.list_routes(app)
    existing_paths = MapSet.new(existing, & &1.path)

    {clean, conflicts} =
      Enum.reduce(incoming_routes, {[], []}, fn route, {clean_acc, conflict_acc} ->
        if MapSet.member?(existing_paths, route.path) do
          existing_route = Enum.find(existing, &(&1.path == route.path))
          conflict = %{
            path: route.path,
            existing: %{methods: existing_route.methods, path_type: existing_route.path_type},
            incoming: %{methods: route.methods, path_type: route.path_type}
          }
          {clean_acc, conflict_acc ++ [conflict]}
        else
          {clean_acc ++ [route], conflict_acc}
        end
      end)

    token = compute_hmac(incoming_routes)

    %__MODULE__{
      parsed: incoming_routes,
      conflicts: conflicts,
      skipped: skipped,
      preview_token: token
    }
  end

  @doc """
  Verifies that a preview token matches the given routes.

  Returns `true` if the HMAC matches, `false` otherwise.
  """
  def verify_token(routes, token) do
    compute_hmac(routes) == token
  end

  @doc """
  Confirms an import by inserting non-conflicting routes into the database.

  Returns `{:ok, inserted_routes}` where inserted_routes is the list of
  successfully created route structs.
  """
  def confirm(%Application{} = app, %__MODULE__{parsed: parsed, conflicts: conflicts}) do
    conflict_paths = MapSet.new(conflicts, & &1.path)

    inserted =
      parsed
      |> Enum.reject(fn route -> MapSet.member?(conflict_paths, route.path) end)
      |> Enum.reduce([], fn route_map, acc ->
        attrs = Map.take(route_map, [:path, :methods, :path_type, :description, :query_params, :headers, :rate_limit, :tags])
        case Routes.create_route(app, attrs) do
          {:ok, route} -> acc ++ [route]
          {:error, _} -> acc
        end
      end)

    {:ok, inserted}
  end

  defp compute_hmac(routes) do
    data = :erlang.term_to_binary(routes)
    :crypto.mac(:hmac, :sha256, @hmac_secret, data) |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/import/preview_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/import/preview.ex test/wagger/import/preview_test.exs
git commit -m "Add import preview with conflict detection and HMAC verification"
```

---

### Task 5: Import Controller and Router

**Files:**
- Create: `lib/wagger_web/controllers/import_controller.ex`
- Create: `lib/wagger_web/controllers/import_json.ex`
- Create: `test/wagger_web/controllers/import_controller_test.exs`
- Modify: `lib/wagger_web/router.ex`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger_web/controllers/import_controller_test.exs
defmodule WaggerWeb.ImportControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})
    {:ok, app} = Applications.create_application(%{name: "test-app"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn, app: app}
  end

  describe "POST /api/applications/:app_id/import/bulk" do
    test "returns preview with parsed routes", %{conn: conn, app: app} do
      body = "GET /api/users\nPOST /api/items - Items"
      conn = post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{"body" => body})
      resp = json_response(conn, 200)
      assert length(resp["parsed"]) == 2
      assert resp["preview_token"] != nil
      assert resp["conflicts"] == []
      assert resp["skipped"] == []
    end

    test "detects conflicts with existing routes", %{conn: conn, app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET"], path_type: "exact"})
      body = "GET,POST /api/users\nGET /api/items"
      conn = post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{"body" => body})
      resp = json_response(conn, 200)
      assert length(resp["conflicts"]) == 1
      assert hd(resp["conflicts"])["path"] == "/api/users"
    end
  end

  describe "POST /api/applications/:app_id/import/openapi" do
    test "returns preview from OpenAPI spec", %{conn: conn, app: app} do
      spec = %{
        "openapi" => "3.0.0",
        "info" => %{"title" => "Test", "version" => "1.0"},
        "paths" => %{
          "/api/users" => %{"get" => %{"summary" => "List"}}
        }
      }
      conn = post(conn, ~p"/api/applications/#{app.id}/import/openapi", %{"spec" => spec})
      resp = json_response(conn, 200)
      assert length(resp["parsed"]) == 1
    end
  end

  describe "POST /api/applications/:app_id/import/accesslog" do
    test "returns preview from access log", %{conn: conn, app: app} do
      log = ~s(10.0.0.1 - - [10/Apr/2026:13:55:36 +0000] "GET /api/users HTTP/1.1" 200 612 "-" "curl")
      conn = post(conn, ~p"/api/applications/#{app.id}/import/accesslog", %{"body" => log})
      resp = json_response(conn, 200)
      assert length(resp["parsed"]) == 1
    end
  end

  describe "POST /api/applications/:app_id/import/confirm" do
    test "inserts routes from a valid preview", %{conn: conn, app: app} do
      # First get a preview
      body = "GET /api/users\nPOST /api/items"
      conn1 = post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{"body" => body})
      preview = json_response(conn1, 200)

      # Then confirm it
      conn2 = post(conn, ~p"/api/applications/#{app.id}/import/confirm", preview)
      resp = json_response(conn2, 201)
      assert length(resp["inserted"]) == 2
      assert length(Routes.list_routes(app)) == 2
    end

    test "rejects tampered preview token", %{conn: conn, app: app} do
      body = "GET /api/users"
      conn1 = post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{"body" => body})
      preview = json_response(conn1, 200)

      # Tamper with the parsed routes
      tampered = %{preview | "parsed" => [%{"path" => "/hacked", "methods" => ["GET"], "path_type" => "exact"}]}
      conn2 = post(conn, ~p"/api/applications/#{app.id}/import/confirm", tampered)
      assert json_response(conn2, 422)["error"] =~ "token"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger_web/controllers/import_controller_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement ImportJSON view**

```elixir
# lib/wagger_web/controllers/import_json.ex
defmodule WaggerWeb.ImportJSON do
  @moduledoc false

  def preview(%{preview: preview}) do
    %{
      preview_token: preview.preview_token,
      parsed: Enum.map(preview.parsed, &route_data/1),
      conflicts: Enum.map(preview.conflicts, &conflict_data/1),
      skipped: preview.skipped || []
    }
  end

  def confirm(%{inserted: inserted}) do
    %{inserted: Enum.map(inserted, &inserted_data/1)}
  end

  defp route_data(route) when is_map(route) do
    %{
      path: route[:path] || route["path"],
      methods: route[:methods] || route["methods"] || ["GET"],
      path_type: route[:path_type] || route["path_type"] || "exact",
      description: route[:description] || route["description"]
    }
  end

  defp conflict_data(conflict) do
    %{
      path: conflict.path,
      existing: conflict.existing,
      incoming: conflict.incoming
    }
  end

  defp inserted_data(route) do
    %{
      id: route.id,
      path: route.path,
      methods: route.methods,
      path_type: route.path_type
    }
  end
end
```

- [ ] **Step 4: Implement ImportController**

```elixir
# lib/wagger_web/controllers/import_controller.ex
defmodule WaggerWeb.ImportController do
  @moduledoc false
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Import.{Bulk, OpenApi, AccessLog, Preview}

  action_fallback WaggerWeb.FallbackController

  def bulk(conn, %{"application_id" => app_id, "body" => body}) do
    app = Applications.get_application!(app_id)
    {routes, skipped} = Bulk.parse(body)
    preview = Preview.build(app, routes, skipped)
    render(conn, :preview, preview: preview)
  end

  def openapi(conn, %{"application_id" => app_id, "spec" => spec}) do
    app = Applications.get_application!(app_id)
    {routes, errors} = OpenApi.parse(spec)
    preview = Preview.build(app, routes, errors)
    render(conn, :preview, preview: preview)
  end

  def accesslog(conn, %{"application_id" => app_id, "body" => body}) do
    app = Applications.get_application!(app_id)
    {routes, skipped} = AccessLog.parse(body)
    preview = Preview.build(app, routes, skipped)
    render(conn, :preview, preview: preview)
  end

  def confirm(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)
    parsed = atomize_parsed(params["parsed"] || [])
    token = params["preview_token"]

    if Preview.verify_token(parsed, token) do
      preview = %Preview{parsed: parsed, conflicts: [], skipped: []}
      {:ok, inserted} = Preview.confirm(app, preview)

      conn
      |> put_status(:created)
      |> render(:confirm, inserted: inserted)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Invalid preview token — routes may have been tampered with"})
    end
  end

  defp atomize_parsed(routes) do
    Enum.map(routes, fn route ->
      %{
        path: route["path"],
        methods: route["methods"],
        path_type: route["path_type"],
        description: route["description"]
      }
    end)
  end
end
```

- [ ] **Step 5: Update router**

Add these routes inside the `scope "/api"` block in `lib/wagger_web/router.ex`, after the export route:

```elixir
post "/applications/:application_id/import/bulk", ImportController, :bulk
post "/applications/:application_id/import/openapi", ImportController, :openapi
post "/applications/:application_id/import/accesslog", ImportController, :accesslog
post "/applications/:application_id/import/confirm", ImportController, :confirm
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
mix test test/wagger_web/controllers/import_controller_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 7: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/wagger_web/controllers/import_controller.ex lib/wagger_web/controllers/import_json.ex lib/wagger_web/router.ex test/wagger_web/controllers/import_controller_test.exs
git commit -m "Add import controller with bulk, openapi, accesslog, and confirm endpoints"
```

---

### Task 6: End-to-End Import Verification

No new files. Manual verification of the full import flow.

- [ ] **Step 1: Start the server and create a user**

```bash
mix run -e '{:ok, _, key} = Wagger.Accounts.create_user(%{username: "admin"}); IO.puts(key)'
```

- [ ] **Step 2: Create an application**

```bash
curl -s -X POST http://localhost:4000/api/applications \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"name": "demo-api"}' | python3 -m json.tool
```

- [ ] **Step 3: Test bulk import preview**

```bash
curl -s -X POST http://localhost:4000/api/applications/1/import/bulk \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"body": "GET /api/users\nGET,POST /api/items - Item CRUD\nDELETE /api/items/:id\n/health"}' | python3 -m json.tool
```

Expected: 4 parsed routes, Express `:id` normalized to `{id}`, no conflicts.

- [ ] **Step 4: Confirm the import using the preview token**

Copy the preview response and POST it to the confirm endpoint:

```bash
curl -s -X POST http://localhost:4000/api/applications/1/import/confirm \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '<paste preview JSON here>' | python3 -m json.tool
```

Expected: 4 inserted routes.

- [ ] **Step 5: Re-import and verify conflicts**

```bash
curl -s -X POST http://localhost:4000/api/applications/1/import/bulk \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"body": "GET /api/users\nGET /api/new-route"}' | python3 -m json.tool
```

Expected: 1 conflict for `/api/users`, 1 clean parsed route.

- [ ] **Step 6: Commit any fixes**

```bash
git add -u && git commit -m "Fix issues found during import end-to-end verification"
```
