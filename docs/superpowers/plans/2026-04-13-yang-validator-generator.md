# YANG Validator + Generator Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a YANG instance data validator on top of ex_yang, define the generator behaviour, create shared YANG types, and implement the Nginx generator as proof of the full pipeline: routes in, YANG-validated config tree, nginx.conf text out.

**Architecture:** The validator walks an Elixir map (instance data) against a resolved YANG module tree from ex_yang, checking mandatory leaves, type constraints, list keys, and enumerations. Each generator implements a behaviour with three callbacks: `yang_module/0`, `map_routes/2`, `serialize/2`. A shared `generate/3` function orchestrates: parse YANG → map routes to instance tree → validate → serialize.

**Tech Stack:** Elixir, ex_yang (path dep), ExUnit. No new dependencies.

---

## File Structure

```
yang/
  wagger-common.yang          — shared typedefs (http-method, path-type, rate-limit)
  wagger-nginx.yang           — nginx WAF config data model
lib/wagger/generator/
  validator.ex                — YANG instance data validator
  generator.ex                — behaviour + shared generate/3
  path_helper.ex              — canonical path to provider-specific patterns
  nginx.ex                    — Nginx generator implementation
test/wagger/generator/
  validator_test.exs
  path_helper_test.exs
  nginx_test.exs
```

---

## ex_yang Data Model Reference

The validator needs to understand these ex_yang structs (from `lib/ex_yang/model/`):

- **`ExYang.Model.Container`** — has `.name`, `.body` (list of child nodes), `.presence`
- **`ExYang.Model.Leaf`** — has `.name`, `.type` (Type struct), `.mandatory` (boolean), `.default`
- **`ExYang.Model.LeafList`** — has `.name`, `.type`, `.min_elements`, `.max_elements`
- **`ExYang.Model.List`** — has `.name`, `.key` (space-separated key leaf names), `.body`, `.min_elements`, `.max_elements`
- **`ExYang.Model.Type`** — has `.name` (resolved base type), `.range`, `.length`, `.patterns`, `.enum_values`
- **`ExYang.Model.EnumValue`** — has `.name`, `.value` (integer)
- **`ExYang.Model.Range`** — has `.expression` (e.g. `"1..65535"`)
- **`ExYang.Model.Length`** — has `.expression` (e.g. `"1..255"`)
- **`ExYang.Model.Pattern`** — has `.value` (regex string), `.modifier` (`:invert_match` or nil)

After `ExYang.resolve/2`, a `ResolvedModule` has `.module.body` which is the list of top-level data nodes.

---

### Task 1: YANG Instance Validator — Core

**Files:**
- Create: `lib/wagger/generator/validator.ex`
- Create: `test/wagger/generator/validator_test.exs`

This is the heart of the plan. The validator checks an Elixir map against a resolved YANG schema tree.

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/generator/validator_test.exs
defmodule Wagger.Generator.ValidatorTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator.Validator

  # A minimal YANG module for testing:
  #   container config {
  #     leaf name { type string; mandatory true; }
  #     leaf port { type uint16; }
  #     leaf mode { type enumeration { enum "block"; enum "allow"; } }
  #     leaf-list tags { type string; }
  #     container nested {
  #       leaf value { type string; }
  #     }
  #     list rules {
  #       key "id";
  #       leaf id { type uint32; mandatory true; }
  #       leaf pattern { type string; }
  #     }
  #   }
  @yang_source """
  module test-validator {
    namespace "urn:test:validator";
    prefix tv;

    container config {
      leaf name {
        type string;
        mandatory true;
      }
      leaf port {
        type uint16;
      }
      leaf mode {
        type enumeration {
          enum "block";
          enum "allow";
        }
      }
      leaf-list tags {
        type string;
      }
      container nested {
        leaf value {
          type string;
        }
      }
      list rules {
        key "id";
        leaf id {
          type uint32;
          mandatory true;
        }
        leaf pattern {
          type string;
        }
      }
    }
  }
  """

  setup_all do
    {:ok, parsed} = ExYang.parse(@yang_source)
    {:ok, resolved} = ExYang.resolve(parsed, %{})
    %{schema: resolved}
  end

  describe "validate/2 with valid data" do
    test "accepts valid complete instance", %{schema: schema} do
      data = %{
        "config" => %{
          "name" => "my-waf",
          "port" => 443,
          "mode" => "block",
          "tags" => ["api", "prod"],
          "nested" => %{"value" => "hello"},
          "rules" => [
            %{"id" => 1, "pattern" => "/admin.*"},
            %{"id" => 2, "pattern" => "/debug.*"}
          ]
        }
      }

      assert :ok = Validator.validate(data, schema)
    end

    test "accepts minimal valid instance (only mandatory fields)", %{schema: schema} do
      data = %{"config" => %{"name" => "minimal"}}
      assert :ok = Validator.validate(data, schema)
    end
  end

  describe "validate/2 mandatory leaf checks" do
    test "rejects missing mandatory leaf", %{schema: schema} do
      data = %{"config" => %{"port" => 80}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
      assert Enum.any?(errors, &String.contains?(&1, "mandatory"))
    end
  end

  describe "validate/2 type checks" do
    test "rejects wrong type for integer leaf", %{schema: schema} do
      data = %{"config" => %{"name" => "test", "port" => "not-an-integer"}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "port"))
    end

    test "rejects wrong type for string leaf", %{schema: schema} do
      data = %{"config" => %{"name" => 123}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
    end

    test "rejects invalid enum value", %{schema: schema} do
      data = %{"config" => %{"name" => "test", "mode" => "invalid"}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "mode"))
    end
  end

  describe "validate/2 list checks" do
    test "rejects list entry missing key leaf", %{schema: schema} do
      data = %{
        "config" => %{
          "name" => "test",
          "rules" => [%{"pattern" => "/admin.*"}]
        }
      }
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "id"))
    end

    test "rejects duplicate list keys", %{schema: schema} do
      data = %{
        "config" => %{
          "name" => "test",
          "rules" => [
            %{"id" => 1, "pattern" => "/a"},
            %{"id" => 1, "pattern" => "/b"}
          ]
        }
      }
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate"))
    end
  end

  describe "validate/2 leaf-list checks" do
    test "rejects non-list value for leaf-list", %{schema: schema} do
      data = %{"config" => %{"name" => "test", "tags" => "not-a-list"}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "tags"))
    end

    test "rejects wrong item type in leaf-list", %{schema: schema} do
      data = %{"config" => %{"name" => "test", "tags" => [123, 456]}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "tags"))
    end
  end

  describe "validate/2 unknown nodes" do
    test "rejects unknown keys in container", %{schema: schema} do
      data = %{"config" => %{"name" => "test", "bogus" => "value"}}
      assert {:error, errors} = Validator.validate(data, schema)
      assert Enum.any?(errors, &String.contains?(&1, "bogus"))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/generator/validator_test.exs
```

Expected: compilation error, module not found.

- [ ] **Step 3: Implement Validator**

```elixir
# lib/wagger/generator/validator.ex
defmodule Wagger.Generator.Validator do
  @moduledoc """
  Validates Elixir map instance data against a resolved YANG module schema.

  Walks the instance data tree against the YANG schema tree from ex_yang,
  checking mandatory leaf presence, type constraints, enumeration values,
  list key uniqueness, and rejecting unknown nodes.

  Built on top of ex_yang's schema parsing and resolution — ex_yang handles
  YANG source → resolved schema; this module handles data → schema conformance.
  """

  alias ExYang.Model.{Container, Leaf, LeafList, List}

  @doc """
  Validates instance data against a resolved YANG schema.

  Returns `:ok` if valid, or `{:error, errors}` where errors is a list of
  human-readable error strings with paths.
  """
  def validate(data, %{module: module}) when is_map(data) do
    errors = validate_children(data, module.body, [])

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  # Validate all children of a container/module body against schema nodes
  defp validate_children(data, schema_nodes, path) when is_map(data) do
    known_names = MapSet.new(schema_nodes, & &1.name)

    # Check for unknown keys
    unknown_errors =
      data
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known_names, &1))
      |> Enum.map(&"#{format_path(path, &1)}: unknown node '#{&1}'")

    # Check each schema node against data
    schema_errors =
      Enum.flat_map(schema_nodes, fn node ->
        validate_node(data, node, path)
      end)

    unknown_errors ++ schema_errors
  end

  # Container node
  defp validate_node(data, %Container{} = node, path) do
    case Map.get(data, node.name) do
      nil -> []
      value when is_map(value) -> validate_children(value, node.body, path ++ [node.name])
      _other -> ["#{format_path(path, node.name)}: expected a map for container"]
    end
  end

  # Leaf node
  defp validate_node(data, %Leaf{} = node, path) do
    case Map.get(data, node.name) do
      nil ->
        if node.mandatory do
          ["#{format_path(path, node.name)}: mandatory leaf missing"]
        else
          []
        end

      value ->
        validate_leaf_type(value, node.type, path ++ [node.name])
    end
  end

  # LeafList node
  defp validate_node(data, %LeafList{} = node, path) do
    case Map.get(data, node.name) do
      nil -> []
      values when is_list(values) ->
        Enum.flat_map(Enum.with_index(values), fn {item, idx} ->
          validate_leaf_type(item, node.type, path ++ [node.name, "[#{idx}]"])
        end)
      _other ->
        ["#{format_path(path, node.name)}: expected a list for leaf-list"]
    end
  end

  # List node
  defp validate_node(data, %List{} = node, path) do
    case Map.get(data, node.name) do
      nil -> []
      entries when is_list(entries) -> validate_list_entries(entries, node, path)
      _other -> ["#{format_path(path, node.name)}: expected a list"]
    end
  end

  # Catch-all for Choice, Case, etc. — skip for now
  defp validate_node(_data, _node, _path), do: []

  # Validate list entries: check keys, uniqueness, and entry contents
  defp validate_list_entries(entries, node, path) do
    key_names = String.split(node.key || "", " ", trim: true)
    list_path = path ++ [node.name]

    # Validate each entry
    entry_errors =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} ->
        entry_path = list_path ++ ["[#{idx}]"]

        # Check mandatory key leaves present
        key_errors =
          Enum.flat_map(key_names, fn key_name ->
            if Map.has_key?(entry, key_name) do
              []
            else
              ["#{format_path(entry_path, key_name)}: mandatory list key missing"]
            end
          end)

        # Validate entry children against list body schema
        child_errors = validate_children(entry, node.body, entry_path)

        key_errors ++ child_errors
      end)

    # Check key uniqueness
    uniqueness_errors =
      if length(key_names) > 0 do
        keys = Enum.map(entries, fn entry ->
          Enum.map(key_names, &Map.get(entry, &1))
        end)

        if length(keys) != length(Enum.uniq(keys)) do
          ["#{format_path(list_path, "")}: duplicate list keys found"]
        else
          []
        end
      else
        []
      end

    entry_errors ++ uniqueness_errors
  end

  # Type validation for leaf values
  defp validate_leaf_type(value, nil, _path), do: if(is_binary(value), do: [], else: [])

  defp validate_leaf_type(value, type, path) do
    base = type.name || "string"
    type_errors = validate_base_type(value, base, path)
    enum_errors = validate_enum(value, type, path)
    type_errors ++ enum_errors
  end

  defp validate_base_type(value, type_name, path) when type_name in ~w(string) do
    if is_binary(value), do: [], else: ["#{format_path(path, nil)}: expected string, got #{inspect(value)}"]
  end

  defp validate_base_type(value, type_name, path)
       when type_name in ~w(int8 int16 int32 int64 uint8 uint16 uint32 uint64) do
    if is_integer(value), do: [], else: ["#{format_path(path, nil)}: expected integer, got #{inspect(value)}"]
  end

  defp validate_base_type(value, "boolean", path) do
    if is_boolean(value), do: [], else: ["#{format_path(path, nil)}: expected boolean, got #{inspect(value)}"]
  end

  defp validate_base_type(value, "enumeration", path) do
    if is_binary(value), do: [], else: ["#{format_path(path, nil)}: expected string for enum, got #{inspect(value)}"]
  end

  defp validate_base_type(_value, _type, _path), do: []

  defp validate_enum(value, %{enum_values: enums}, path) when is_list(enums) and length(enums) > 0 do
    valid_names = Enum.map(enums, & &1.name)
    if value in valid_names do
      []
    else
      ["#{format_path(path, nil)}: invalid enum value '#{value}', expected one of: #{Enum.join(valid_names, ", ")}"]
    end
  end

  defp validate_enum(_value, _type, _path), do: []

  defp format_path(path, nil), do: "/" <> Enum.join(path, "/")
  defp format_path(path, name), do: "/" <> Enum.join(path ++ [name], "/")
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/generator/validator_test.exs
```

Expected: 11 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/validator.ex test/wagger/generator/validator_test.exs
git commit -m "Add YANG instance data validator on top of ex_yang"
```

---

### Task 2: Path Helper

**Files:**
- Create: `lib/wagger/generator/path_helper.ex`
- Create: `test/wagger/generator/path_helper_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/generator/path_helper_test.exs
defmodule Wagger.Generator.PathHelperTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator.PathHelper

  describe "to_regex/1" do
    test "exact path without params" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/users$"
    end

    test "exact path with params" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/users/[^/]+$"
    end

    test "prefix path" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_regex(route) == "^/static/.*"
    end

    test "regex path passes through" do
      route = %{path: "^/api/v[12]/.*", path_type: "regex"}
      assert PathHelper.to_regex(route) == "^/api/v[12]/.*"
    end

    test "multiple params" do
      route = %{path: "/api/{org}/users/{id}", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/[^/]+/users/[^/]+$"
    end
  end

  describe "to_wildcard/1" do
    test "exact path without params" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_wildcard(route) == "/api/users"
    end

    test "exact path with params" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_wildcard(route) == "/api/users/*"
    end

    test "prefix path" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_wildcard(route) == "/static/*"
    end
  end

  describe "to_nginx_location/1" do
    test "exact path without params" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_nginx_location(route) == {:exact, "/api/users"}
    end

    test "exact path with params" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_nginx_location(route) == {:regex, "^/api/users/[^/]+$"}
    end

    test "prefix path" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_nginx_location(route) == {:prefix, "/static/"}
    end

    test "regex path" do
      route = %{path: "^/api/v[12]/.*", path_type: "regex"}
      assert PathHelper.to_nginx_location(route) == {:regex, "^/api/v[12]/.*"}
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/generator/path_helper_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement PathHelper**

```elixir
# lib/wagger/generator/path_helper.ex
defmodule Wagger.Generator.PathHelper do
  @moduledoc """
  Translates canonical route paths into provider-specific patterns.

  Canonical paths use OpenAPI-style `{param}` placeholders. This module
  converts them to regex patterns, wildcard patterns, and nginx location
  directives depending on the target provider.
  """

  @doc """
  Converts a route to a regex pattern string.

  - `{param}` placeholders become `[^/]+`
  - Exact paths get `^...$` anchors
  - Prefix paths get `^....*` (start anchor, trailing wildcard)
  - Regex paths pass through unchanged
  """
  def to_regex(%{path_type: "regex", path: path}), do: path

  def to_regex(%{path_type: "prefix", path: path}) do
    pattern = String.replace(path, ~r/\{[^}]+\}/, "[^/]+")
    "^#{pattern}.*"
  end

  def to_regex(%{path: path}) do
    pattern = String.replace(path, ~r/\{[^}]+\}/, "[^/]+")
    "^#{pattern}$"
  end

  @doc """
  Converts a route to a wildcard pattern (for providers like AWS WAF).

  - `{param}` placeholders become `*`
  - Prefix paths get a trailing `*`
  """
  def to_wildcard(%{path_type: "prefix", path: path}) do
    pattern = String.replace(path, ~r/\{[^}]+\}/, "*")
    if String.ends_with?(pattern, "/"), do: pattern <> "*", else: pattern <> "/*"
  end

  def to_wildcard(%{path: path}) do
    String.replace(path, ~r/\{[^}]+\}/, "*")
  end

  @doc """
  Converts a route to an nginx location directive type and pattern.

  Returns `{type, pattern}` where type is `:exact`, `:prefix`, or `:regex`.

  - Exact paths without params use `= /path` (exact match)
  - Exact paths with params use `~ ^/path/[^/]+$` (regex)
  - Prefix paths use `/path/` (prefix match)
  - Regex paths use `~ ^pattern` (regex)
  """
  def to_nginx_location(%{path_type: "regex", path: path}), do: {:regex, path}
  def to_nginx_location(%{path_type: "prefix", path: path}), do: {:prefix, path}

  def to_nginx_location(%{path: path} = route) do
    if String.contains?(path, "{") do
      {:regex, to_regex(route)}
    else
      {:exact, path}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/generator/path_helper_test.exs
```

Expected: 12 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/path_helper.ex test/wagger/generator/path_helper_test.exs
git commit -m "Add path helper for canonical-to-provider path translation"
```

---

### Task 3: Generator Behaviour + Shared Logic

**Files:**
- Create: `lib/wagger/generator/generator.ex`

- [ ] **Step 1: Implement the behaviour and shared generate function**

```elixir
# lib/wagger/generator/generator.ex
defmodule Wagger.Generator do
  @moduledoc """
  Behaviour and shared orchestration for WAF config generators.

  Each provider implements three callbacks:
  - `yang_module/0` — returns the YANG source for this provider's config schema
  - `map_routes/2` — maps routes + config into a YANG instance data tree
  - `serialize/2` — converts a validated instance tree to the provider's native format

  The shared `generate/3` function orchestrates the pipeline:
  1. Parse and resolve the YANG module
  2. Call `map_routes/2` to build the instance tree
  3. Validate the instance against the YANG schema
  4. Call `serialize/2` to produce the output string
  """

  alias Wagger.Generator.Validator

  @callback yang_module() :: String.t()
  @callback map_routes(routes :: [map()], config :: map()) :: map()
  @callback serialize(instance :: map(), schema :: struct()) :: String.t()

  @doc """
  Generates WAF configuration for the given provider module.

  Returns `{:ok, output_string}` on success or `{:error, reason}` on failure.
  """
  def generate(provider_module, routes, config) do
    yang_source = provider_module.yang_module()

    with {:ok, parsed} <- ExYang.parse(yang_source),
         {:ok, resolved} <- ExYang.resolve(parsed, %{}),
         instance = provider_module.map_routes(routes, config),
         :ok <- Validator.validate(instance, resolved) do
      output = provider_module.serialize(instance, resolved)
      {:ok, output}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 2: Verify compilation**

```bash
mix compile
```

Expected: compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/wagger/generator/generator.ex
git commit -m "Add Generator behaviour with YANG-validated pipeline"
```

---

### Task 4: Common YANG Types

**Files:**
- Create: `yang/wagger-common.yang`

- [ ] **Step 1: Write the common YANG module**

```yang
// yang/wagger-common.yang
module wagger-common {
  namespace "urn:wagger:common";
  prefix wc;

  organization "Wagger Project";
  description "Shared types for WAF configuration generators.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  typedef http-method {
    type enumeration {
      enum "GET";
      enum "POST";
      enum "PUT";
      enum "PATCH";
      enum "DELETE";
      enum "HEAD";
      enum "OPTIONS";
    }
    description "Standard HTTP methods.";
  }

  typedef path-type {
    type enumeration {
      enum "exact";
      enum "prefix";
      enum "regex";
    }
    description "How a route path should be matched.";
  }

  typedef rate-limit {
    type uint32 {
      range "1..1000000";
    }
    description "Requests per minute rate limit.";
  }

  typedef path-pattern {
    type string {
      length "1..4096";
    }
    description "A URL path pattern with optional {param} placeholders.";
  }
}
```

- [ ] **Step 2: Verify it parses with ex_yang**

```bash
mix run -e '
  source = File.read!("yang/wagger-common.yang")
  {:ok, parsed} = ExYang.parse(source)
  IO.puts("Parsed: #{parsed.name}")
'
```

Expected: `Parsed: wagger-common`

- [ ] **Step 3: Commit**

```bash
git add yang/wagger-common.yang
git commit -m "Add wagger-common YANG module with shared WAF types"
```

---

### Task 5: Nginx YANG Model

**Files:**
- Create: `yang/wagger-nginx.yang`

- [ ] **Step 1: Write the Nginx YANG model**

This models the abstract structure of an nginx WAF config: a server block containing a map for path validation, location blocks with method restrictions and rate limits.

```yang
// yang/wagger-nginx.yang
module wagger-nginx {
  namespace "urn:wagger:nginx";
  prefix wn;

  organization "Wagger Project";
  description "Data model for nginx WAF-style allowlist configuration.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container nginx-config {
    description "Top-level nginx WAF configuration.";

    leaf config-name {
      type string;
      mandatory true;
      description "Name prefix for generated config elements.";
    }

    leaf generated-at {
      type string;
      description "ISO 8601 timestamp of generation.";
    }

    container path-map {
      description "Map directive entries for path validation.";

      leaf default-value {
        type string;
        mandatory true;
        description "Default map value for unmatched paths.";
      }

      list entries {
        key "pattern";
        description "Map entries matching valid paths.";

        leaf pattern {
          type string;
          mandatory true;
          description "Regex or exact path pattern.";
        }

        leaf value {
          type string;
          mandatory true;
          description "Map value when pattern matches.";
        }
      }
    }

    list locations {
      key "path";
      description "Location blocks with method and rate limit configuration.";

      leaf path {
        type string;
        mandatory true;
        description "Location match pattern.";
      }

      leaf match-type {
        type enumeration {
          enum "exact";
          enum "prefix";
          enum "regex";
        }
        mandatory true;
        description "Nginx location match type.";
      }

      leaf-list allowed-methods {
        type string;
        description "HTTP methods allowed at this location.";
      }

      container rate-limit {
        description "Rate limiting configuration for this location.";

        leaf zone-name {
          type string;
          mandatory true;
          description "Nginx limit_req zone name.";
        }

        leaf burst {
          type uint32;
          mandatory true;
          description "Burst size for limit_req.";
        }
      }

      leaf upstream {
        type string;
        description "Proxy pass target.";
      }
    }
  }
}
```

- [ ] **Step 2: Verify it parses and resolves**

```bash
mix run -e '
  source = File.read!("yang/wagger-nginx.yang")
  {:ok, parsed} = ExYang.parse(source)
  {:ok, resolved} = ExYang.resolve(parsed, %{})
  IO.puts("Resolved: #{resolved.module.name}, nodes: #{length(resolved.module.body)}")
'
```

Expected: `Resolved: wagger-nginx, nodes: 1` (one top-level container)

- [ ] **Step 3: Commit**

```bash
git add yang/wagger-nginx.yang
git commit -m "Add wagger-nginx YANG model for nginx WAF config"
```

---

### Task 6: Nginx Generator

**Files:**
- Create: `lib/wagger/generator/nginx.ex`
- Create: `test/wagger/generator/nginx_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/generator/nginx_test.exs
defmodule Wagger.Generator.NginxTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Nginx

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact",
      rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact",
      rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix",
      rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact",
      rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp", upstream: "http://backend:8080"}

  describe "map_routes/2" do
    test "produces valid instance tree" do
      instance = Nginx.map_routes(@routes, @config)
      config = instance["nginx-config"]
      assert config["config-name"] == "myapp"
      assert config["path-map"]["default-value"] == "0"
      assert length(config["path-map"]["entries"]) == 4
      assert length(config["locations"]) == 4
    end

    test "sets correct match-type for locations" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]
      static = Enum.find(locations, &(&1["match-type"] == "prefix"))
      assert static["path"] == "/static/"
    end

    test "includes rate-limit only for rate-limited routes" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]
      users = Enum.find(locations, &(&1["path"] =~ ~r{^/api/users$|^= /api/users}))
      assert users["rate-limit"] != nil
      health = Enum.find(locations, &(&1["path"] =~ "health"))
      refute Map.has_key?(health, "rate-limit")
    end
  end

  describe "full generate pipeline" do
    test "generates valid nginx config through YANG validation" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "map $request_uri $valid_path"
      assert output =~ "default 0"
      assert output =~ "/api/users"
      assert output =~ "limit_except GET POST"
      assert output =~ "proxy_pass http://backend:8080"
    end

    test "config contains location blocks" do
      {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "location = /api/users"
      assert output =~ "location ~ ^/api/users/[^/]+$"
      assert output =~ "location /static/"
      assert output =~ "location = /health"
    end

    test "config contains rate limiting for rate-limited routes" do
      {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "limit_req zone="
      assert output =~ "burst="
    end

    test "config blocks unknown paths" do
      {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "if ($valid_path = 0)"
      assert output =~ "return 403"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/generator/nginx_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement Nginx generator**

```elixir
# lib/wagger/generator/nginx.ex
defmodule Wagger.Generator.Nginx do
  @moduledoc """
  Generates nginx WAF-style allowlist configuration.

  Produces an nginx config snippet with:
  - A `map` directive for path validation (block unknown paths)
  - `location` blocks with `limit_except` for method enforcement
  - `limit_req` directives for rate-limited routes
  - `proxy_pass` to the configured upstream

  Config is validated against the wagger-nginx YANG model before serialization.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @impl true
  def yang_module do
    File.read!(Path.join(:code.priv_dir(:wagger), "../yang/wagger-nginx.yang"))
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"] || "wagger"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    map_entries =
      Enum.map(routes, fn route ->
        pattern = PathHelper.to_regex(route)
        %{"pattern" => pattern, "value" => "1"}
      end)

    locations =
      Enum.map(routes, fn route ->
        {match_type, path} = location_for_route(route)

        loc = %{
          "path" => path,
          "match-type" => match_type,
          "allowed-methods" => route.methods || route[:methods] || ["GET"],
          "upstream" => config[:upstream] || config["upstream"] || "http://upstream"
        }

        rate = route[:rate_limit] || route.rate_limit

        if rate do
          zone_name = "#{prefix}_#{String.replace(route.path || route[:path], ~r/[^a-zA-Z0-9]/, "_")}"
          Map.put(loc, "rate-limit", %{
            "zone-name" => zone_name,
            "burst" => max(1, trunc(rate * 0.2))
          })
        else
          loc
        end
      end)

    %{
      "nginx-config" => %{
        "config-name" => prefix,
        "generated-at" => now,
        "path-map" => %{
          "default-value" => "0",
          "entries" => map_entries
        },
        "locations" => locations
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    config = instance["nginx-config"]
    prefix = config["config-name"]
    map_entries = config["path-map"]["entries"]
    locations = config["locations"]

    lines = []
    lines = lines ++ ["# WAF-style allowlist for #{prefix}"]
    lines = lines ++ ["# Generated #{config["generated-at"]}"]
    lines = lines ++ [""]

    # Map directive
    lines = lines ++ ["map $request_uri $valid_path {"]
    lines = lines ++ ["  default #{config["path-map"]["default-value"]};"]
    lines = lines ++ Enum.map(map_entries, fn entry ->
      "  ~#{entry["pattern"]}  #{entry["value"]};"
    end)
    lines = lines ++ ["}"]
    lines = lines ++ [""]

    # Server block
    lines = lines ++ ["server {"]
    lines = lines ++ ["  if ($valid_path = 0) {"]
    lines = lines ++ ["    return 403;"]
    lines = lines ++ ["  }"]
    lines = lines ++ [""]

    # Location blocks
    location_lines =
      Enum.flat_map(locations, fn loc ->
        directive = case loc["match-type"] do
          "exact" -> "location = #{loc["path"]}"
          "prefix" -> "location #{loc["path"]}"
          "regex" -> "location ~ #{loc["path"]}"
        end

        methods = loc["allowed-methods"] || []

        block = ["  #{directive} {"]
        block = block ++ ["    limit_except #{Enum.join(methods, " ")} {"]
        block = block ++ ["      deny all;"]
        block = block ++ ["    }"]

        block = if loc["rate-limit"] do
          rl = loc["rate-limit"]
          block ++ ["    limit_req zone=#{rl["zone-name"]} burst=#{rl["burst"]} nodelay;"]
        else
          block
        end

        block = block ++ ["    proxy_pass #{loc["upstream"]};"]
        block = block ++ ["  }"]
        block ++ [""]
      end)

    lines = lines ++ location_lines
    lines = lines ++ ["}"]

    Enum.join(lines, "\n")
  end

  defp location_for_route(route) do
    case PathHelper.to_nginx_location(route) do
      {:exact, path} -> {"exact", path}
      {:prefix, path} -> {"prefix", path}
      {:regex, pattern} -> {"regex", pattern}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger/generator/nginx_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/generator/nginx.ex test/wagger/generator/nginx_test.exs
git commit -m "Add Nginx generator with YANG-validated config pipeline"
```

---

### Task 7: Verify Full Pipeline End-to-End

No new files. Manual verification that routes → YANG validation → nginx config works.

- [ ] **Step 1: Test the pipeline in iex**

```bash
mix run -e '
  routes = [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]
  config = %{prefix: "myapp", upstream: "http://backend:8080"}
  {:ok, output} = Wagger.Generator.generate(Wagger.Generator.Nginx, routes, config)
  IO.puts(output)
'
```

Expected: complete nginx config with map directive, location blocks, limit_except, rate limiting, proxy_pass.

- [ ] **Step 2: Verify YANG validation catches bad data**

```bash
mix run -e '
  # Intentionally break the map_routes output to test validation
  yang = File.read!("yang/wagger-nginx.yang")
  {:ok, parsed} = ExYang.parse(yang)
  {:ok, resolved} = ExYang.resolve(parsed, %{})
  # Missing mandatory config-name
  bad_data = %{"nginx-config" => %{"path-map" => %{"default-value" => "0", "entries" => []}}}
  result = Wagger.Generator.Validator.validate(bad_data, resolved)
  IO.inspect(result, label: "Validation result")
'
```

Expected: `{:error, ["...config-name...mandatory..."]}` or similar.

- [ ] **Step 3: Commit any fixes**

```bash
git add -u && git commit -m "Fix issues found during generator e2e verification"
```
