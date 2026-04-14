# Wagger Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working Phoenix API for managing applications and routes with API key authentication, backed by SQLite, using EDN for structured field storage.

**Architecture:** Monolith Phoenix app with `ecto_sqlite3`. Ecto custom types handle EDN serialization for structured fields (methods, tags, query_params, headers). API versioning via Accept header plug. API key auth via Bearer token plug.

**Tech Stack:** Elixir 1.17+, Phoenix 1.7, LiveView (scaffolded but UI deferred to Plan 7), ecto_sqlite3, jason, eden (EDN codec)

---

### Task 1: Scaffold Phoenix Project

**Files:**
- Create: `mix.exs`
- Create: `config/config.exs`
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Create: `config/prod.exs`
- Create: `config/runtime.exs`
- Create: `lib/wagger/application.ex`
- Create: `lib/wagger/repo.ex`
- Create: `lib/wagger_web/endpoint.ex`
- Create: `lib/wagger_web/router.ex`

- [ ] **Step 1: Generate the Phoenix project**

Run inside a distrobox with Elixir installed (per CLAUDE.md, Elixir is an exception — no distrobox needed):

```bash
cd /home/imsmith/github
mix phx.new wagger --database sqlite3 --no-mailer --no-dashboard --no-gettext
```

Answer `Y` to install dependencies.

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/imsmith/github/wagger
mix deps.get && mix compile
```

Expected: compiles with 0 errors.

- [ ] **Step 3: Add eden dependency to mix.exs**

Add to the `deps` function in `mix.exs`:

```elixir
{:eden, "~> 2.0"}
```

If `eden` is not available on hex, we'll write a minimal EDN codec in Task 2 instead. Check first:

```bash
mix deps.get
```

Expected: resolves successfully, or we pivot to Task 2 alternative.

- [ ] **Step 4: Add ex_yang as a path dependency**

Add to `deps` in `mix.exs`:

```elixir
{:ex_yang, path: "../ex_yang"}
```

```bash
mix deps.get && mix compile
```

Expected: compiles with ex_yang available.

- [ ] **Step 5: Update license in mix.exs**

In the `project` function, add:

```elixir
license: "AGPL-3.0-only"
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Scaffold Phoenix project with sqlite3, ex_yang, eden deps"
```

---

### Task 2: EDN Ecto Custom Types

**Files:**
- Create: `lib/wagger/ecto/edn_list.ex`
- Create: `lib/wagger/ecto/edn_map_list.ex`
- Create: `test/wagger/ecto/edn_list_test.exs`
- Create: `test/wagger/ecto/edn_map_list_test.exs`

Two custom Ecto types: `EdnList` for simple keyword/string lists (methods, tags) and `EdnMapList` for lists of maps (query_params, headers).

- [ ] **Step 1: Write failing test for EdnList**

```elixir
# test/wagger/ecto/edn_list_test.exs
defmodule Wagger.Ecto.EdnListTest do
  use ExUnit.Case, async: true

  alias Wagger.Ecto.EdnList

  describe "cast/1" do
    test "casts a list of strings" do
      assert {:ok, ["GET", "POST"]} = EdnList.cast(["GET", "POST"])
    end

    test "casts a list of atoms" do
      assert {:ok, ["GET", "POST"]} = EdnList.cast([:GET, :POST])
    end

    test "rejects non-list" do
      assert :error = EdnList.cast("not a list")
    end
  end

  describe "dump/1" do
    test "serializes list to EDN string" do
      assert {:ok, "[:GET :POST]"} = EdnList.dump(["GET", "POST"])
    end

    test "serializes empty list" do
      assert {:ok, "[]"} = EdnList.dump([])
    end
  end

  describe "load/1" do
    test "deserializes EDN string to list of strings" do
      assert {:ok, ["GET", "POST"]} = EdnList.load("[:GET :POST]")
    end

    test "loads empty list" do
      assert {:ok, []} = EdnList.load("[]")
    end

    test "loads nil as empty list" do
      assert {:ok, []} = EdnList.load(nil)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger/ecto/edn_list_test.exs
```

Expected: compilation error, module `Wagger.Ecto.EdnList` not found.

- [ ] **Step 3: Implement EdnList**

```elixir
# lib/wagger/ecto/edn_list.ex
defmodule Wagger.Ecto.EdnList do
  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list) do
    {:ok, Enum.map(list, &to_string/1)}
  end

  def cast(_), do: :error

  @impl true
  def dump(list) when is_list(list) do
    edn =
      list
      |> Enum.map(fn item -> ":#{item}" end)
      |> Enum.join(" ")

    {:ok, "[#{edn}]"}
  end

  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(edn_string) when is_binary(edn_string) do
    items =
      edn_string
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim()
      |> case do
        "" -> []
        content ->
          content
          |> String.split(~r/\s+/)
          |> Enum.map(fn item -> String.trim_leading(item, ":") end)
      end

    {:ok, items}
  end

  def load(_), do: :error
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/wagger/ecto/edn_list_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Write failing test for EdnMapList**

```elixir
# test/wagger/ecto/edn_map_list_test.exs
defmodule Wagger.Ecto.EdnMapListTest do
  use ExUnit.Case, async: true

  alias Wagger.Ecto.EdnMapList

  describe "cast/1" do
    test "casts a list of maps" do
      input = [%{"name" => "page", "required" => false}]
      assert {:ok, [%{"name" => "page", "required" => false}]} = EdnMapList.cast(input)
    end

    test "casts a list of keyword-keyed maps" do
      input = [%{name: "page", required: false}]
      assert {:ok, [%{"name" => "page", "required" => false}]} = EdnMapList.cast(input)
    end

    test "rejects non-list" do
      assert :error = EdnMapList.cast("not a list")
    end
  end

  describe "dump/1" do
    test "serializes list of maps to EDN" do
      input = [%{"name" => "page", "required" => false}]
      {:ok, edn} = EdnMapList.dump(input)
      assert edn =~ "{:name \"page\""
      assert edn =~ ":required false"
    end

    test "serializes empty list" do
      assert {:ok, "[]"} = EdnMapList.dump([])
    end
  end

  describe "load/1" do
    test "deserializes EDN string to list of maps" do
      edn = "[{:name \"page\" :required false}]"
      {:ok, result} = EdnMapList.load(edn)
      assert [%{"name" => "page", "required" => false}] = result
    end

    test "loads nil as empty list" do
      assert {:ok, []} = EdnMapList.load(nil)
    end
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

```bash
mix test test/wagger/ecto/edn_map_list_test.exs
```

Expected: compilation error, module not found.

- [ ] **Step 7: Implement EdnMapList**

```elixir
# lib/wagger/ecto/edn_map_list.ex
defmodule Wagger.Ecto.EdnMapList do
  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list) do
    normalized =
      Enum.map(list, fn map ->
        Map.new(map, fn {k, v} -> {to_string(k), v} end)
      end)

    {:ok, normalized}
  end

  def cast(_), do: :error

  @impl true
  def dump(list) when is_list(list) do
    maps_edn =
      Enum.map(list, fn map ->
        pairs =
          Enum.map(map, fn {k, v} ->
            ":#{k} #{encode_value(v)}"
          end)

        "{#{Enum.join(pairs, " ")}}"
      end)

    {:ok, "[#{Enum.join(maps_edn, " ")}]"}
  end

  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(edn_string) when is_binary(edn_string) do
    case parse_map_list(edn_string) do
      {:ok, maps} -> {:ok, maps}
      :error -> :error
    end
  end

  def load(_), do: :error

  defp encode_value(v) when is_binary(v), do: "\"#{v}\""
  defp encode_value(v) when is_boolean(v), do: to_string(v)
  defp encode_value(v) when is_integer(v), do: to_string(v)
  defp encode_value(nil), do: "nil"
  defp encode_value(v) when is_atom(v), do: ":#{v}"

  defp parse_map_list(edn) do
    content =
      edn
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim()

    case content do
      "" ->
        {:ok, []}

      _ ->
        maps =
          Regex.scan(~r/\{([^}]*)\}/, content)
          |> Enum.map(fn [_, inner] -> parse_map_pairs(inner) end)

        {:ok, maps}
    end
  end

  defp parse_map_pairs(inner) do
    # Tokenize: keywords start with :, strings are quoted, booleans/integers are bare
    tokens = tokenize(String.trim(inner), [])

    tokens
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, val] ->
      {String.trim_leading(key, ":"), parse_value(val)}
    end)
  end

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(<<"\"", rest::binary>>, acc) do
    {str, remaining} = consume_string(rest, "")
    tokenize(String.trim_leading(remaining), [str | acc])
  end

  defp tokenize(<<":", rest::binary>>, acc) do
    {word, remaining} = consume_word(rest, "")
    tokenize(String.trim_leading(remaining), [":" <> word | acc])
  end

  defp tokenize(input, acc) do
    {word, remaining} = consume_word(input, "")
    tokenize(String.trim_leading(remaining), [word | acc])
  end

  defp consume_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp consume_string(<<c::utf8, rest::binary>>, acc), do: consume_string(rest, acc <> <<c::utf8>>)

  defp consume_word(<<c::utf8, rest::binary>>, acc) when c in ~c[ \t\n\r}], do: {acc, <<c::utf8, rest::binary>>}
  defp consume_word(<<c::utf8, rest::binary>>, acc), do: consume_word(rest, acc <> <<c::utf8>>)
  defp consume_word("", acc), do: {acc, ""}

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false
  defp parse_value("nil"), do: nil

  defp parse_value(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> val
    end
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

```bash
mix test test/wagger/ecto/edn_map_list_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/wagger/ecto/ test/wagger/ecto/
git commit -m "Add EDN Ecto custom types for list and map-list fields"
```

---

### Task 3: Database Migrations

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_applications.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_routes.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_snapshots.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_users.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_credentials.exs`

- [ ] **Step 1: Generate migration for applications**

```bash
mix ecto.gen.migration create_applications
```

Edit the generated file:

```elixir
defmodule Wagger.Repo.Migrations.CreateApplications do
  use Ecto.Migration

  def change do
    create table(:applications) do
      add :name, :string, null: false
      add :description, :text
      add :tags, :text

      timestamps(type: :string)
    end

    create unique_index(:applications, [:name])
  end
end
```

- [ ] **Step 2: Generate migration for routes**

```bash
mix ecto.gen.migration create_routes
```

```elixir
defmodule Wagger.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  def change do
    create table(:routes) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :methods, :text, null: false
      add :path_type, :string, null: false, default: "exact"
      add :description, :text
      add :query_params, :text
      add :headers, :text
      add :rate_limit, :integer
      add :tags, :text

      timestamps(type: :string)
    end

    create index(:routes, [:application_id])
    create unique_index(:routes, [:application_id, :path])
  end
end
```

- [ ] **Step 3: Generate migration for snapshots**

```bash
mix ecto.gen.migration create_snapshots
```

```elixir
defmodule Wagger.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  def change do
    create table(:snapshots) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :config_params, :text
      add :route_snapshot, :text, null: false
      add :output, :text, null: false
      add :checksum, :string, null: false

      timestamps(type: :string, updated_at: false)
    end

    create index(:snapshots, [:application_id])
    create index(:snapshots, [:application_id, :provider])
  end
end
```

- [ ] **Step 4: Generate migration for users**

```bash
mix ecto.gen.migration create_users
```

```elixir
defmodule Wagger.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :display_name, :string
      add :password_hash, :string
      add :api_key_hash, :string

      timestamps(type: :string)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:api_key_hash])
  end
end
```

- [ ] **Step 5: Generate migration for credentials**

```bash
mix ecto.gen.migration create_credentials
```

```elixir
defmodule Wagger.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :label, :string
      add :credential_data, :binary, null: false

      timestamps(type: :string, updated_at: false)
    end

    create index(:credentials, [:user_id])
  end
end
```

- [ ] **Step 6: Run migrations**

```bash
mix ecto.create && mix ecto.migrate
```

Expected: 5 migrations run successfully.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/
git commit -m "Add database migrations for all tables"
```

---

### Task 4: Application Schema and Context

**Files:**
- Create: `lib/wagger/applications/application.ex`
- Create: `lib/wagger/applications.ex`
- Create: `test/wagger/applications_test.exs`

- [ ] **Step 1: Write failing test for Applications context**

```elixir
# test/wagger/applications_test.exs
defmodule Wagger.ApplicationsTest do
  use Wagger.DataCase

  alias Wagger.Applications

  describe "create_application/1" do
    test "creates with valid attrs" do
      attrs = %{name: "my-api", description: "Test API", tags: ["api", "public"]}
      assert {:ok, app} = Applications.create_application(attrs)
      assert app.name == "my-api"
      assert app.description == "Test API"
      assert app.tags == ["api", "public"]
    end

    test "rejects duplicate name" do
      attrs = %{name: "my-api"}
      assert {:ok, _} = Applications.create_application(attrs)
      assert {:error, changeset} = Applications.create_application(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "requires name" do
      assert {:error, changeset} = Applications.create_application(%{})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "list_applications/0" do
    test "returns all applications" do
      {:ok, _} = Applications.create_application(%{name: "app-1"})
      {:ok, _} = Applications.create_application(%{name: "app-2"})
      assert length(Applications.list_applications()) == 2
    end
  end

  describe "list_applications/1" do
    test "filters by tag" do
      {:ok, _} = Applications.create_application(%{name: "tagged", tags: ["api"]})
      {:ok, _} = Applications.create_application(%{name: "untagged", tags: []})
      results = Applications.list_applications(%{"tag" => "api"})
      assert length(results) == 1
      assert hd(results).name == "tagged"
    end
  end

  describe "get_application!/1" do
    test "returns the application" do
      {:ok, app} = Applications.create_application(%{name: "my-api"})
      assert Applications.get_application!(app.id).name == "my-api"
    end
  end

  describe "update_application/2" do
    test "updates with valid attrs" do
      {:ok, app} = Applications.create_application(%{name: "my-api"})
      assert {:ok, updated} = Applications.update_application(app, %{description: "Updated"})
      assert updated.description == "Updated"
    end
  end

  describe "delete_application/1" do
    test "deletes the application" do
      {:ok, app} = Applications.create_application(%{name: "my-api"})
      assert {:ok, _} = Applications.delete_application(app)
      assert_raise Ecto.NoResultsError, fn -> Applications.get_application!(app.id) end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger/applications_test.exs
```

Expected: compilation error, modules not found.

- [ ] **Step 3: Create DataCase test helper if not present**

Check if `test/support/data_case.ex` exists from scaffolding. If not, create:

```elixir
# test/support/data_case.ex
defmodule Wagger.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Wagger.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Wagger.DataCase
    end
  end

  setup tags do
    Wagger.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Wagger.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

- [ ] **Step 4: Implement Application schema**

```elixir
# lib/wagger/applications/application.ex
defmodule Wagger.Applications.Application do
  use Ecto.Schema
  import Ecto.Changeset

  schema "applications" do
    field :name, :string
    field :description, :string
    field :tags, Wagger.Ecto.EdnList

    has_many :routes, Wagger.Applications.Route

    timestamps(type: :string)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:name, :description, :tags])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9\-]*$/, message: "must be a lowercase slug")
    |> unique_constraint(:name)
  end
end
```

- [ ] **Step 5: Implement Applications context**

```elixir
# lib/wagger/applications.ex
defmodule Wagger.Applications do
  import Ecto.Query
  alias Wagger.Repo
  alias Wagger.Applications.Application

  def list_applications(filters \\ %{}) do
    Application
    |> apply_filters(filters)
    |> Repo.all()
  end

  def get_application!(id), do: Repo.get!(Application, id)

  def create_application(attrs) do
    %Application{}
    |> Application.changeset(attrs)
    |> Repo.insert()
  end

  def update_application(%Application{} = app, attrs) do
    app
    |> Application.changeset(attrs)
    |> Repo.update()
  end

  def delete_application(%Application{} = app) do
    Repo.delete(app)
  end

  defp apply_filters(query, %{"tag" => tag}) do
    # EDN list stored as "[:tag1 :tag2]", search for the keyword
    where(query, [a], like(a.tags, ^"%:#{tag}%"))
  end

  defp apply_filters(query, _), do: query
end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
mix test test/wagger/applications_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/wagger/applications/ lib/wagger/applications.ex test/wagger/applications_test.exs test/support/
git commit -m "Add Application schema and context with CRUD operations"
```

---

### Task 5: Route Schema and Context

**Files:**
- Create: `lib/wagger/applications/route.ex`
- Create: `lib/wagger/routes.ex`
- Create: `test/wagger/routes_test.exs`

- [ ] **Step 1: Write failing test for Routes context**

```elixir
# test/wagger/routes_test.exs
defmodule Wagger.RoutesTest do
  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Routes

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    %{app: app}
  end

  describe "create_route/2" do
    test "creates with valid attrs", %{app: app} do
      attrs = %{
        path: "/api/users",
        methods: ["GET", "POST"],
        path_type: "exact",
        description: "User endpoint",
        rate_limit: 100,
        tags: ["api"]
      }

      assert {:ok, route} = Routes.create_route(app, attrs)
      assert route.path == "/api/users"
      assert route.methods == ["GET", "POST"]
      assert route.path_type == "exact"
      assert route.rate_limit == 100
    end

    test "defaults to GET method", %{app: app} do
      attrs = %{path: "/health", path_type: "exact"}
      assert {:ok, route} = Routes.create_route(app, attrs)
      assert route.methods == ["GET"]
    end

    test "rejects duplicate path within same app", %{app: app} do
      attrs = %{path: "/api/users", methods: ["GET"], path_type: "exact"}
      assert {:ok, _} = Routes.create_route(app, attrs)
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert "has already been taken" in errors_on(changeset).path
    end

    test "requires path", %{app: app} do
      assert {:error, changeset} = Routes.create_route(app, %{})
      assert "can't be blank" in errors_on(changeset).path
    end

    test "validates path_type", %{app: app} do
      attrs = %{path: "/foo", path_type: "invalid"}
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert "is invalid" in errors_on(changeset).path_type
    end
  end

  describe "list_routes/1" do
    test "returns routes for an application", %{app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/a", path_type: "exact"})
      {:ok, _} = Routes.create_route(app, %{path: "/b", path_type: "exact"})
      assert length(Routes.list_routes(app)) == 2
    end
  end

  describe "list_routes/2" do
    test "filters by tag", %{app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/a", path_type: "exact", tags: ["api"]})
      {:ok, _} = Routes.create_route(app, %{path: "/b", path_type: "exact", tags: ["public"]})
      results = Routes.list_routes(app, %{"tag" => "api"})
      assert length(results) == 1
      assert hd(results).path == "/a"
    end

    test "filters by method", %{app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/a", methods: ["GET"], path_type: "exact"})
      {:ok, _} = Routes.create_route(app, %{path: "/b", methods: ["POST"], path_type: "exact"})
      results = Routes.list_routes(app, %{"method" => "POST"})
      assert length(results) == 1
      assert hd(results).path == "/b"
    end

    test "filters by path_type", %{app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/a", path_type: "exact"})
      {:ok, _} = Routes.create_route(app, %{path: "/b/", path_type: "prefix"})
      results = Routes.list_routes(app, %{"path_type" => "prefix"})
      assert length(results) == 1
      assert hd(results).path == "/b/"
    end
  end

  describe "get_route!/2" do
    test "returns the route", %{app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      assert Routes.get_route!(app, route.id).path == "/test"
    end
  end

  describe "update_route/2" do
    test "updates with valid attrs", %{app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      assert {:ok, updated} = Routes.update_route(route, %{rate_limit: 50})
      assert updated.rate_limit == 50
    end
  end

  describe "delete_route/1" do
    test "deletes the route", %{app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      assert {:ok, _} = Routes.delete_route(route)
      assert_raise Ecto.NoResultsError, fn -> Routes.get_route!(app, route.id) end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger/routes_test.exs
```

Expected: compilation error, modules not found.

- [ ] **Step 3: Implement Route schema**

```elixir
# lib/wagger/applications/route.ex
defmodule Wagger.Applications.Route do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_path_types ~w(exact prefix regex)

  schema "routes" do
    field :path, :string
    field :methods, Wagger.Ecto.EdnList
    field :path_type, :string, default: "exact"
    field :description, :string
    field :query_params, Wagger.Ecto.EdnMapList
    field :headers, Wagger.Ecto.EdnMapList
    field :rate_limit, :integer
    field :tags, Wagger.Ecto.EdnList

    belongs_to :application, Wagger.Applications.Application

    timestamps(type: :string)
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [:path, :methods, :path_type, :description, :query_params, :headers, :rate_limit, :tags])
    |> validate_required([:path, :path_type])
    |> validate_inclusion(:path_type, @valid_path_types)
    |> put_default_methods()
    |> unique_constraint([:application_id, :path])
  end

  defp put_default_methods(changeset) do
    case get_field(changeset, :methods) do
      nil -> put_change(changeset, :methods, ["GET"])
      [] -> put_change(changeset, :methods, ["GET"])
      _ -> changeset
    end
  end
end
```

- [ ] **Step 4: Implement Routes context**

```elixir
# lib/wagger/routes.ex
defmodule Wagger.Routes do
  import Ecto.Query
  alias Wagger.Repo
  alias Wagger.Applications.{Application, Route}

  def list_routes(%Application{} = app, filters \\ %{}) do
    Route
    |> where([r], r.application_id == ^app.id)
    |> apply_filters(filters)
    |> Repo.all()
  end

  def get_route!(%Application{} = app, id) do
    Route
    |> where([r], r.application_id == ^app.id and r.id == ^id)
    |> Repo.one!()
  end

  def create_route(%Application{} = app, attrs) do
    %Route{application_id: app.id}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  def update_route(%Route{} = route, attrs) do
    route
    |> Route.changeset(attrs)
    |> Repo.update()
  end

  def delete_route(%Route{} = route) do
    Repo.delete(route)
  end

  defp apply_filters(query, filters) do
    query
    |> maybe_filter_tag(filters)
    |> maybe_filter_method(filters)
    |> maybe_filter_path_type(filters)
  end

  defp maybe_filter_tag(query, %{"tag" => tag}) do
    where(query, [r], like(r.tags, ^"%:#{tag}%"))
  end

  defp maybe_filter_tag(query, _), do: query

  defp maybe_filter_method(query, %{"method" => method}) do
    where(query, [r], like(r.methods, ^"%:#{method}%"))
  end

  defp maybe_filter_method(query, _), do: query

  defp maybe_filter_path_type(query, %{"path_type" => path_type}) do
    where(query, [r], r.path_type == ^path_type)
  end

  defp maybe_filter_path_type(query, _), do: query
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/wagger/routes_test.exs
```

Expected: 11 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/applications/route.ex lib/wagger/routes.ex test/wagger/routes_test.exs
git commit -m "Add Route schema and context with CRUD and filtering"
```

---

### Task 6: API Version Plug

**Files:**
- Create: `lib/wagger_web/plugs/api_version.ex`
- Create: `test/wagger_web/plugs/api_version_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# test/wagger_web/plugs/api_version_test.exs
defmodule WaggerWeb.Plugs.ApiVersionTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias WaggerWeb.Plugs.ApiVersion

  test "extracts version from vnd.wagger+json accept header" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/vnd.wagger+json; version=1")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "defaults to version 1 with plain application/json" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/json")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "defaults to version 1 with no accept header" do
    conn =
      conn(:get, "/api/applications")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "extracts version 2" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/vnd.wagger+json; version=2")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 2
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger_web/plugs/api_version_test.exs
```

Expected: compilation error, module not found.

- [ ] **Step 3: Implement ApiVersion plug**

```elixir
# lib/wagger_web/plugs/api_version.ex
defmodule WaggerWeb.Plugs.ApiVersion do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    version =
      conn
      |> get_req_header("accept")
      |> List.first("")
      |> extract_version()

    assign(conn, :api_version, version)
  end

  defp extract_version(accept) do
    case Regex.run(~r/application\/vnd\.wagger\+json;\s*version=(\d+)/, accept) do
      [_, version] -> String.to_integer(version)
      _ -> 1
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/wagger_web/plugs/api_version_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/plugs/api_version.ex test/wagger_web/plugs/api_version_test.exs
git commit -m "Add API version plug for Accept header content negotiation"
```

---

### Task 7: API Key Authentication

**Files:**
- Create: `lib/wagger/accounts/user.ex`
- Create: `lib/wagger/accounts.ex`
- Create: `lib/wagger_web/plugs/authenticate.ex`
- Create: `test/wagger/accounts_test.exs`
- Create: `test/wagger_web/plugs/authenticate_test.exs`

- [ ] **Step 1: Write failing test for Accounts context**

```elixir
# test/wagger/accounts_test.exs
defmodule Wagger.AccountsTest do
  use Wagger.DataCase

  alias Wagger.Accounts

  describe "create_user/1" do
    test "creates user and returns API key" do
      assert {:ok, user, api_key} = Accounts.create_user(%{username: "ian", display_name: "Ian"})
      assert user.username == "ian"
      assert is_binary(api_key)
      assert String.length(api_key) > 20
      assert user.api_key_hash != nil
    end

    test "rejects duplicate username" do
      {:ok, _, _} = Accounts.create_user(%{username: "ian"})
      assert {:error, changeset} = Accounts.create_user(%{username: "ian"})
      assert "has already been taken" in errors_on(changeset).username
    end

    test "requires username" do
      assert {:error, changeset} = Accounts.create_user(%{})
      assert "can't be blank" in errors_on(changeset).username
    end
  end

  describe "authenticate_by_api_key/1" do
    test "returns user for valid key" do
      {:ok, user, api_key} = Accounts.create_user(%{username: "ian"})
      assert {:ok, found} = Accounts.authenticate_by_api_key(api_key)
      assert found.id == user.id
    end

    test "returns error for invalid key" do
      assert :error = Accounts.authenticate_by_api_key("bogus-key")
    end
  end

  describe "setup_required?/0" do
    test "returns true when no users exist" do
      assert Accounts.setup_required?()
    end

    test "returns false when users exist" do
      {:ok, _, _} = Accounts.create_user(%{username: "ian"})
      refute Accounts.setup_required?()
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement User schema**

```elixir
# lib/wagger/accounts/user.ex
defmodule Wagger.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :password_hash, :string
    field :api_key_hash, :string

    # has_many :credentials added in Plan 6 (Advanced Auth)

    timestamps(type: :string)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :password_hash, :api_key_hash])
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9_\-]*$/, message: "must be a lowercase slug")
    |> unique_constraint(:username)
    |> unique_constraint(:api_key_hash)
  end
end
```

- [ ] **Step 4: Implement Accounts context**

```elixir
# lib/wagger/accounts.ex
defmodule Wagger.Accounts do
  alias Wagger.Repo
  alias Wagger.Accounts.User

  def create_user(attrs) do
    api_key = generate_api_key()
    api_key_hash = hash_api_key(api_key)

    result =
      %User{}
      |> User.changeset(Map.put(attrs, :api_key_hash, api_key_hash))
      |> Repo.insert()

    case result do
      {:ok, user} -> {:ok, user, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def authenticate_by_api_key(api_key) do
    hash = hash_api_key(api_key)

    case Repo.get_by(User, api_key_hash: hash) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  def setup_required? do
    Repo.aggregate(User, :count) == 0
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
```

- [ ] **Step 5: Run Accounts tests**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Write failing test for Authenticate plug**

```elixir
# test/wagger_web/plugs/authenticate_test.exs
defmodule WaggerWeb.Plugs.AuthenticateTest do
  use Wagger.DataCase
  use Plug.Test

  alias WaggerWeb.Plugs.Authenticate
  alias Wagger.Accounts

  test "authenticates valid Bearer token" do
    {:ok, user, api_key} = Accounts.create_user(%{username: "ian"})

    conn =
      conn(:get, "/api/applications")
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns[:current_user].id == user.id
    refute conn.halted
  end

  test "rejects invalid Bearer token" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("authorization", "Bearer bad-key")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects missing authorization header" do
    conn =
      conn(:get, "/api/applications")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "allows unauthenticated access during setup" do
    # No users exist, so setup mode is active
    conn =
      conn(:get, "/api/applications")
      |> Authenticate.call(Authenticate.init(allow_setup: true))

    refute conn.halted
    assert conn.assigns[:setup_mode] == true
  end
end
```

- [ ] **Step 7: Run test to verify it fails**

```bash
mix test test/wagger_web/plugs/authenticate_test.exs
```

Expected: compilation error.

- [ ] **Step 8: Implement Authenticate plug**

```elixir
# lib/wagger_web/plugs/authenticate.ex
defmodule WaggerWeb.Plugs.Authenticate do
  import Plug.Conn
  alias Wagger.Accounts

  def init(opts), do: opts

  def call(conn, opts) do
    case extract_bearer_token(conn) do
      {:ok, token} ->
        case Accounts.authenticate_by_api_key(token) do
          {:ok, user} -> assign(conn, :current_user, user)
          :error -> unauthorized(conn)
        end

      :missing ->
        if Keyword.get(opts, :allow_setup, false) and Accounts.setup_required?() do
          conn
          |> assign(:setup_mode, true)
          |> assign(:current_user, nil)
        else
          unauthorized(conn)
        end
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :missing
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
```

- [ ] **Step 9: Run tests to verify they pass**

```bash
mix test test/wagger_web/plugs/authenticate_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/wagger/accounts/ lib/wagger/accounts.ex lib/wagger_web/plugs/authenticate.ex test/wagger/accounts_test.exs test/wagger_web/plugs/authenticate_test.exs
git commit -m "Add user accounts, API key auth, and authenticate plug"
```

---

### Task 8: Application API Controller

**Files:**
- Create: `lib/wagger_web/controllers/application_controller.ex`
- Create: `lib/wagger_web/controllers/application_json.ex`
- Create: `test/wagger_web/controllers/application_controller_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# test/wagger_web/controllers/application_controller_test.exs
defmodule WaggerWeb.ApplicationControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn}
  end

  describe "GET /api/applications" do
    test "lists all applications", %{conn: conn} do
      {:ok, _} = Applications.create_application(%{name: "app-one", tags: ["api"]})
      conn = get(conn, ~p"/api/applications")
      assert [%{"name" => "app-one"}] = json_response(conn, 200)["data"]
    end

    test "filters by tag", %{conn: conn} do
      {:ok, _} = Applications.create_application(%{name: "tagged", tags: ["api"]})
      {:ok, _} = Applications.create_application(%{name: "other", tags: ["web"]})
      conn = get(conn, ~p"/api/applications?tag=api")
      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["name"] == "tagged"
    end
  end

  describe "POST /api/applications" do
    test "creates application with valid data", %{conn: conn} do
      conn = post(conn, ~p"/api/applications", %{name: "new-app", description: "A new app", tags: ["api"]})
      assert %{"name" => "new-app"} = json_response(conn, 201)["data"]
    end

    test "returns errors with invalid data", %{conn: conn} do
      conn = post(conn, ~p"/api/applications", %{})
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "GET /api/applications/:id" do
    test "shows application", %{conn: conn} do
      {:ok, app} = Applications.create_application(%{name: "my-app"})
      conn = get(conn, ~p"/api/applications/#{app.id}")
      assert %{"name" => "my-app"} = json_response(conn, 200)["data"]
    end
  end

  describe "PUT /api/applications/:id" do
    test "updates application", %{conn: conn} do
      {:ok, app} = Applications.create_application(%{name: "my-app"})
      conn = put(conn, ~p"/api/applications/#{app.id}", %{description: "Updated"})
      assert %{"description" => "Updated"} = json_response(conn, 200)["data"]
    end
  end

  describe "DELETE /api/applications/:id" do
    test "deletes application", %{conn: conn} do
      {:ok, app} = Applications.create_application(%{name: "my-app"})
      conn = delete(conn, ~p"/api/applications/#{app.id}")
      assert response(conn, 204)
    end
  end

  describe "unauthenticated" do
    test "returns 401 without token" do
      conn = build_conn()
      conn = get(conn, ~p"/api/applications")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger_web/controllers/application_controller_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Create ConnCase test helper if needed**

Check if `test/support/conn_case.ex` exists from scaffolding. If not, create:

```elixir
# test/support/conn_case.ex
defmodule WaggerWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint WaggerWeb.Endpoint

      use WaggerWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Wagger.DataCase, only: [errors_on: 1]
    end
  end

  setup tags do
    Wagger.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

- [ ] **Step 4: Implement ApplicationController**

```elixir
# lib/wagger_web/controllers/application_controller.ex
defmodule WaggerWeb.ApplicationController do
  use WaggerWeb, :controller

  alias Wagger.Applications

  action_fallback WaggerWeb.FallbackController

  def index(conn, params) do
    applications = Applications.list_applications(params)
    render(conn, :index, applications: applications)
  end

  def create(conn, params) do
    with {:ok, application} <- Applications.create_application(params) do
      conn
      |> put_status(:created)
      |> render(:show, application: application)
    end
  end

  def show(conn, %{"id" => id}) do
    application = Applications.get_application!(id)
    render(conn, :show, application: application)
  end

  def update(conn, %{"id" => id} = params) do
    application = Applications.get_application!(id)

    with {:ok, application} <- Applications.update_application(application, params) do
      render(conn, :show, application: application)
    end
  end

  def delete(conn, %{"id" => id}) do
    application = Applications.get_application!(id)

    with {:ok, _} <- Applications.delete_application(application) do
      send_resp(conn, :no_content, "")
    end
  end
end
```

- [ ] **Step 5: Implement ApplicationJSON view**

```elixir
# lib/wagger_web/controllers/application_json.ex
defmodule WaggerWeb.ApplicationJSON do
  alias Wagger.Applications.Application

  def index(%{applications: applications}) do
    %{data: for(app <- applications, do: data(app))}
  end

  def show(%{application: application}) do
    %{data: data(application)}
  end

  defp data(%Application{} = app) do
    %{
      id: app.id,
      name: app.name,
      description: app.description,
      tags: app.tags || [],
      inserted_at: app.inserted_at,
      updated_at: app.updated_at
    }
  end
end
```

- [ ] **Step 6: Create FallbackController**

```elixir
# lib/wagger_web/controllers/fallback_controller.ex
defmodule WaggerWeb.FallbackController do
  use WaggerWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: WaggerWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end
end
```

- [ ] **Step 7: Create ChangesetJSON view**

```elixir
# lib/wagger_web/controllers/changeset_json.ex
defmodule WaggerWeb.ChangesetJSON do
  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
```

- [ ] **Step 8: Wire up the router**

Update `lib/wagger_web/router.ex`:

```elixir
defmodule WaggerWeb.Router do
  use WaggerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug WaggerWeb.Plugs.ApiVersion
    plug WaggerWeb.Plugs.Authenticate
  end

  scope "/api", WaggerWeb do
    pipe_through :api

    resources "/applications", ApplicationController, except: [:new, :edit]
  end
end
```

- [ ] **Step 9: Run tests to verify they pass**

```bash
mix test test/wagger_web/controllers/application_controller_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/wagger_web/controllers/ lib/wagger_web/router.ex test/wagger_web/controllers/ test/support/
git commit -m "Add Application API controller with CRUD endpoints"
```

---

### Task 9: Route API Controller

**Files:**
- Create: `lib/wagger_web/controllers/route_controller.ex`
- Create: `lib/wagger_web/controllers/route_json.ex`
- Create: `test/wagger_web/controllers/route_controller_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# test/wagger_web/controllers/route_controller_test.exs
defmodule WaggerWeb.RouteControllerTest do
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

  describe "GET /api/applications/:app_id/routes" do
    test "lists routes for an application", %{conn: conn, app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/users", methods: ["GET"], path_type: "exact"})
      conn = get(conn, ~p"/api/applications/#{app.id}/routes")
      assert [%{"path" => "/users"}] = json_response(conn, 200)["data"]
    end

    test "filters by tag", %{conn: conn, app: app} do
      {:ok, _} = Routes.create_route(app, %{path: "/a", path_type: "exact", tags: ["api"]})
      {:ok, _} = Routes.create_route(app, %{path: "/b", path_type: "exact", tags: ["web"]})
      conn = get(conn, ~p"/api/applications/#{app.id}/routes?tag=api")
      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["path"] == "/a"
    end
  end

  describe "POST /api/applications/:app_id/routes" do
    test "creates route with valid data", %{conn: conn, app: app} do
      attrs = %{path: "/api/users/{id}", methods: ["GET", "PUT"], path_type: "exact", rate_limit: 100}
      conn = post(conn, ~p"/api/applications/#{app.id}/routes", attrs)
      data = json_response(conn, 201)["data"]
      assert data["path"] == "/api/users/{id}"
      assert data["methods"] == ["GET", "PUT"]
      assert data["rate_limit"] == 100
    end

    test "returns errors with invalid data", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/routes", %{})
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "GET /api/applications/:app_id/routes/:id" do
    test "shows route", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      conn = get(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}")
      assert %{"path" => "/test"} = json_response(conn, 200)["data"]
    end
  end

  describe "PUT /api/applications/:app_id/routes/:id" do
    test "updates route", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      conn = put(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}", %{rate_limit: 50})
      assert %{"rate_limit" => 50} = json_response(conn, 200)["data"]
    end
  end

  describe "DELETE /api/applications/:app_id/routes/:id" do
    test "deletes route", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, %{path: "/test", path_type: "exact"})
      conn = delete(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}")
      assert response(conn, 204)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger_web/controllers/route_controller_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement RouteController**

```elixir
# lib/wagger_web/controllers/route_controller.ex
defmodule WaggerWeb.RouteController do
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Routes

  action_fallback WaggerWeb.FallbackController

  def index(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)
    routes = Routes.list_routes(app, params)
    render(conn, :index, routes: routes)
  end

  def create(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)

    with {:ok, route} <- Routes.create_route(app, params) do
      conn
      |> put_status(:created)
      |> render(:show, route: route)
    end
  end

  def show(conn, %{"application_id" => app_id, "id" => id}) do
    app = Applications.get_application!(app_id)
    route = Routes.get_route!(app, id)
    render(conn, :show, route: route)
  end

  def update(conn, %{"application_id" => app_id, "id" => id} = params) do
    app = Applications.get_application!(app_id)
    route = Routes.get_route!(app, id)

    with {:ok, route} <- Routes.update_route(route, params) do
      render(conn, :show, route: route)
    end
  end

  def delete(conn, %{"application_id" => app_id, "id" => id}) do
    app = Applications.get_application!(app_id)
    route = Routes.get_route!(app, id)

    with {:ok, _} <- Routes.delete_route(route) do
      send_resp(conn, :no_content, "")
    end
  end
end
```

- [ ] **Step 4: Implement RouteJSON view**

```elixir
# lib/wagger_web/controllers/route_json.ex
defmodule WaggerWeb.RouteJSON do
  alias Wagger.Applications.Route

  def index(%{routes: routes}) do
    %{data: for(route <- routes, do: data(route))}
  end

  def show(%{route: route}) do
    %{data: data(route)}
  end

  defp data(%Route{} = route) do
    %{
      id: route.id,
      application_id: route.application_id,
      path: route.path,
      methods: route.methods || ["GET"],
      path_type: route.path_type,
      description: route.description,
      query_params: route.query_params || [],
      headers: route.headers || [],
      rate_limit: route.rate_limit,
      tags: route.tags || [],
      inserted_at: route.inserted_at,
      updated_at: route.updated_at
    }
  end
end
```

- [ ] **Step 5: Update router to add route resource**

In `lib/wagger_web/router.ex`, inside the `/api` scope:

```elixir
resources "/applications", ApplicationController, except: [:new, :edit] do
  resources "/routes", RouteController, except: [:new, :edit]
end
```

Replace the standalone `resources "/applications"` line with this nested version.

- [ ] **Step 6: Run tests to verify they pass**

```bash
mix test test/wagger_web/controllers/route_controller_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/controllers/route_controller.ex lib/wagger_web/controllers/route_json.ex lib/wagger_web/router.ex test/wagger_web/controllers/route_controller_test.exs
git commit -m "Add Route API controller with nested CRUD endpoints"
```

---

### Task 10: Export Endpoint

**Files:**
- Create: `lib/wagger/export.ex`
- Create: `lib/wagger_web/controllers/export_controller.ex`
- Create: `test/wagger/export_test.exs`
- Create: `test/wagger_web/controllers/export_controller_test.exs`

- [ ] **Step 1: Write failing test for Export module**

```elixir
# test/wagger/export_test.exs
defmodule Wagger.ExportTest do
  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Export

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})

    {:ok, _} =
      Routes.create_route(app, %{
        path: "/api/users",
        methods: ["GET", "POST"],
        path_type: "exact",
        description: "User endpoint",
        rate_limit: 100,
        tags: ["api"]
      })

    %{app: app}
  end

  describe "to_edn/1" do
    test "exports routes as EDN string", %{app: app} do
      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":version \"1.0\""
      assert edn =~ ":path \"/api/users\""
      assert edn =~ ":methods [:GET :POST]"
      assert edn =~ ":path-type :exact"
      assert edn =~ ":rate-limit 100"
    end

    test "exports empty routes", _context do
      {:ok, app} = Applications.create_application(%{name: "empty-app"})
      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":routes []"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/wagger/export_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement Export module**

```elixir
# lib/wagger/export.ex
defmodule Wagger.Export do
  alias Wagger.Routes

  def to_edn(app) do
    routes = Routes.list_routes(app)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    routes_edn =
      routes
      |> Enum.map(&route_to_edn/1)
      |> Enum.join("\n   ")

    edn = """
    {:version "1.0"
     :exported "#{now}"
     :routes [#{routes_edn}]}
    """

    {:ok, String.trim(edn)}
  end

  defp route_to_edn(route) do
    methods_edn = Enum.map(route.methods || ["GET"], &":#{&1}") |> Enum.join(" ")
    tags_edn = Enum.map(route.tags || [], &":#{&1}") |> Enum.join(" ")
    qp_edn = encode_map_list(route.query_params || [])
    headers_edn = encode_map_list(route.headers || [])

    fields = [
      ":path \"#{route.path}\"",
      ":methods [#{methods_edn}]",
      ":path-type :#{route.path_type}",
      ":description \"#{route.description || ""}\"",
      ":query-params #{qp_edn}",
      ":headers #{headers_edn}",
      ":rate-limit #{route.rate_limit || "nil"}",
      ":tags [#{tags_edn}]"
    ]

    "{#{Enum.join(fields, "\n     ")}}"
  end

  defp encode_map_list([]), do: "[]"

  defp encode_map_list(maps) do
    inner =
      Enum.map(maps, fn map ->
        pairs =
          Enum.map(map, fn {k, v} ->
            ":#{k} #{encode_value(v)}"
          end)

        "{#{Enum.join(pairs, " ")}}"
      end)

    "[#{Enum.join(inner, " ")}]"
  end

  defp encode_value(v) when is_binary(v), do: "\"#{v}\""
  defp encode_value(v) when is_boolean(v), do: to_string(v)
  defp encode_value(v) when is_integer(v), do: to_string(v)
  defp encode_value(nil), do: "nil"
end
```

- [ ] **Step 4: Run Export tests**

```bash
mix test test/wagger/export_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Write failing test for ExportController**

```elixir
# test/wagger_web/controllers/export_controller_test.exs
defmodule WaggerWeb.ExportControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _} = Routes.create_route(app, %{path: "/health", path_type: "exact"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn, app: app}
  end

  describe "GET /api/applications/:app_id/export" do
    test "returns EDN content", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/export")
      assert response_content_type(conn, :text) =~ "edn"
      body = response(conn, 200)
      assert body =~ ":path \"/health\""
      assert body =~ ":version \"1.0\""
    end
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

```bash
mix test test/wagger_web/controllers/export_controller_test.exs
```

Expected: compilation error.

- [ ] **Step 7: Implement ExportController**

```elixir
# lib/wagger_web/controllers/export_controller.ex
defmodule WaggerWeb.ExportController do
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Export

  def show(conn, %{"application_id" => app_id}) do
    app = Applications.get_application!(app_id)
    {:ok, edn} = Export.to_edn(app)

    conn
    |> put_resp_content_type("application/edn")
    |> send_resp(200, edn)
  end
end
```

- [ ] **Step 8: Update router to add export route**

In `lib/wagger_web/router.ex`, inside the `/api` scope, add after the applications resource block:

```elixir
get "/applications/:application_id/export", ExportController, :show
```

- [ ] **Step 9: Run tests to verify they pass**

```bash
mix test test/wagger_web/controllers/export_controller_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 10: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 11: Commit**

```bash
git add lib/wagger/export.ex lib/wagger_web/controllers/export_controller.ex lib/wagger_web/router.ex test/wagger/export_test.exs test/wagger_web/controllers/export_controller_test.exs
git commit -m "Add EDN export endpoint for application routes"
```

---

### Task 11: Verify End-to-End

No new files. Manual verification that the full API works.

- [ ] **Step 1: Start the server**

```bash
mix phx.server
```

- [ ] **Step 2: Create a user (if setup mode allows, or via iex)**

```bash
mix run -e "
  {:ok, _user, key} = Wagger.Accounts.create_user(%{username: \"admin\"})
  IO.puts(\"API Key: #{key}\")
"
```

Save the printed API key.

- [ ] **Step 3: Test the API with curl**

```bash
# Create an application
curl -s -X POST http://localhost:4000/api/applications \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-api", "description": "Test", "tags": ["api"]}' | jq .

# Create a route
curl -s -X POST http://localhost:4000/api/applications/1/routes \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"path": "/api/users/{id}", "methods": ["GET", "PUT"], "path_type": "exact", "rate_limit": 100}' | jq .

# Export as EDN
curl -s http://localhost:4000/api/applications/1/export \
  -H "Authorization: Bearer <KEY>"

# Verify auth rejection
curl -s http://localhost:4000/api/applications | jq .
```

Expected: 201 for create, EDN output for export, 401 for unauthenticated.

- [ ] **Step 4: Stop the server and commit any fixes**

If any issues were found and fixed:

```bash
git add -u
git commit -m "Fix issues found during end-to-end verification"
```
