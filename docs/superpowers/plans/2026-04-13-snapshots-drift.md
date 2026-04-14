# Snapshots + Drift Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track WAF config generation history with snapshots and detect drift between current routes and last-generated configs per provider.

**Architecture:** The Snapshot schema stores frozen route data, generated output, and a checksum per generation event. The Drift module computes diffs on demand by comparing current routes against the last snapshot. Three API controllers handle generation (which creates snapshots), snapshot history, and drift queries. The generate endpoint ties into the existing `Wagger.Generator.generate/3` pipeline.

**Tech Stack:** Elixir, Phoenix, Ecto, Jason. No new dependencies.

---

## File Structure

```
lib/wagger/
  snapshots/
    snapshot.ex             — Ecto schema
  snapshots.ex              — context (create, list, get, latest)
  drift.ex                  — drift detection logic
lib/wagger_web/controllers/
  generate_controller.ex    — POST /api/applications/:app_id/generate/:provider
  snapshot_controller.ex    — GET snapshots list and show
  drift_controller.ex       — GET drift/:provider
  generate_json.ex
  snapshot_json.ex
  drift_json.ex
test/wagger/
  snapshots_test.exs
  drift_test.exs
test/wagger_web/controllers/
  generate_controller_test.exs
  snapshot_controller_test.exs
  drift_controller_test.exs
```

## Existing Infrastructure

- Snapshots migration exists (`priv/repo/migrations/20260414023757_create_snapshots.exs`)
- `Wagger.Generator.generate/3` takes `(provider_module, routes, config)` and returns `{:ok, output}`
- Provider modules: `Wagger.Generator.{Nginx, Aws, Cloudflare, Azure, Gcp, Caddy}`
- `Wagger.Routes.list_routes/1` returns routes for an app
- `Wagger.Export` has EDN encoding helpers
- OTP 28 timestamp workaround: use `@timestamps_opts` with custom autogenerate (see `lib/wagger/applications/application.ex` for the pattern)

---

### Task 1: Snapshot Schema and Context

**Files:**
- Create: `lib/wagger/snapshots/snapshot.ex`
- Create: `lib/wagger/snapshots.ex`
- Create: `test/wagger/snapshots_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/snapshots_test.exs
defmodule Wagger.SnapshotsTest do
  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Snapshots

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    %{app: app}
  end

  describe "create_snapshot/1" do
    test "creates a snapshot", %{app: app} do
      attrs = %{
        application_id: app.id,
        provider: "nginx",
        config_params: "{:prefix \"myapp\"}",
        route_snapshot: "[{:path \"/api/users\"}]",
        output: "server { ... }",
        checksum: "abc123"
      }

      assert {:ok, snapshot} = Snapshots.create_snapshot(attrs)
      assert snapshot.provider == "nginx"
      assert snapshot.checksum == "abc123"
    end
  end

  describe "list_snapshots/2" do
    test "returns snapshots for app", %{app: app} do
      create_snapshot(app, "nginx")
      create_snapshot(app, "aws")
      snapshots = Snapshots.list_snapshots(app)
      assert length(snapshots) == 2
    end

    test "filters by provider", %{app: app} do
      create_snapshot(app, "nginx")
      create_snapshot(app, "aws")
      snapshots = Snapshots.list_snapshots(app, %{"provider" => "nginx"})
      assert length(snapshots) == 1
      assert hd(snapshots).provider == "nginx"
    end

    test "orders by inserted_at descending", %{app: app} do
      {:ok, s1} = create_snapshot(app, "nginx")
      {:ok, s2} = create_snapshot(app, "nginx")
      [first, second] = Snapshots.list_snapshots(app, %{"provider" => "nginx"})
      assert first.id >= second.id
    end
  end

  describe "get_snapshot!/2" do
    test "returns snapshot scoped to app", %{app: app} do
      {:ok, snapshot} = create_snapshot(app, "nginx")
      assert Snapshots.get_snapshot!(app, snapshot.id).id == snapshot.id
    end
  end

  describe "latest_snapshot/2" do
    test "returns most recent snapshot for provider", %{app: app} do
      create_snapshot(app, "nginx")
      {:ok, s2} = create_snapshot(app, "nginx")
      latest = Snapshots.latest_snapshot(app, "nginx")
      assert latest.id == s2.id
    end

    test "returns nil when no snapshots exist", %{app: app} do
      assert Snapshots.latest_snapshot(app, "nginx") == nil
    end
  end

  defp create_snapshot(app, provider) do
    Snapshots.create_snapshot(%{
      application_id: app.id,
      provider: provider,
      config_params: "{}",
      route_snapshot: "[]",
      output: "output-#{provider}",
      checksum: "check-#{:erlang.unique_integer()}"
    })
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/snapshots_test.exs
```

- [ ] **Step 3: Implement Snapshot schema**

```elixir
# lib/wagger/snapshots/snapshot.ex
defmodule Wagger.Snapshots.Snapshot do
  @moduledoc """
  Ecto schema for a generation snapshot — a frozen record of what WAF config
  was generated, when, for which provider, and from which routes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {Wagger.Applications.Application, :timestamp_now, []}
  ]

  schema "snapshots" do
    field :provider, :string
    field :config_params, :string
    field :route_snapshot, :string
    field :output, :string
    field :checksum, :string

    belongs_to :application, Wagger.Applications.Application

    timestamps(type: :string, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:application_id, :provider, :config_params, :route_snapshot, :output, :checksum])
    |> validate_required([:application_id, :provider, :route_snapshot, :output, :checksum])
  end
end
```

- [ ] **Step 4: Implement Snapshots context**

```elixir
# lib/wagger/snapshots.ex
defmodule Wagger.Snapshots do
  @moduledoc """
  Context for managing generation snapshots. Stores frozen route data and
  generated WAF config output for drift detection and history.
  """

  import Ecto.Query
  alias Wagger.Repo
  alias Wagger.Snapshots.Snapshot
  alias Wagger.Applications.Application

  def create_snapshot(attrs) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  def list_snapshots(%Application{} = app, filters \\ %{}) do
    Snapshot
    |> where([s], s.application_id == ^app.id)
    |> maybe_filter_provider(filters)
    |> order_by([s], desc: s.id)
    |> Repo.all()
  end

  def get_snapshot!(%Application{} = app, id) do
    Snapshot
    |> where([s], s.application_id == ^app.id and s.id == ^id)
    |> Repo.one!()
  end

  def latest_snapshot(%Application{} = app, provider) do
    Snapshot
    |> where([s], s.application_id == ^app.id and s.provider == ^provider)
    |> order_by([s], desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_filter_provider(query, %{"provider" => provider}) do
    where(query, [s], s.provider == ^provider)
  end

  defp maybe_filter_provider(query, _), do: query
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/wagger/snapshots_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/snapshots/ lib/wagger/snapshots.ex test/wagger/snapshots_test.exs
git commit -m "Add Snapshot schema and context with CRUD and filtering"
```

---

### Task 2: Drift Detection Module

**Files:**
- Create: `lib/wagger/drift.ex`
- Create: `test/wagger/drift_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger/drift_test.exs
defmodule Wagger.DriftTest do
  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Drift

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100})
    {:ok, _} = Routes.create_route(app, %{path: "/health", methods: ["GET"], path_type: "exact"})
    %{app: app}
  end

  describe "detect/2 with no snapshots" do
    test "returns never_generated status", %{app: app} do
      result = Drift.detect(app, "nginx")
      assert result.status == :never_generated
    end
  end

  describe "detect/2 with current snapshot" do
    test "returns current when routes haven't changed", %{app: app} do
      routes = Routes.list_routes(app)
      checksum = Drift.compute_checksum(routes)
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: routes_to_edn(routes),
        output: "server {}",
        checksum: checksum
      })

      result = Drift.detect(app, "nginx")
      assert result.status == :current
    end
  end

  describe "detect/2 with drifted snapshot" do
    test "detects added routes", %{app: app} do
      # Snapshot with only /health
      old_routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      checksum = Drift.compute_checksum(old_routes)
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(old_routes) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert length(result.changes.added) == 1
      assert hd(result.changes.added).path == "/api/users"
    end

    test "detects removed routes", %{app: app} do
      # Snapshot with extra route that no longer exists
      old_routes = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/api/legacy", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]
      checksum = Drift.compute_checksum(old_routes)
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(old_routes) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert length(result.changes.removed) == 1
      assert hd(result.changes.removed).path == "/api/legacy"
    end

    test "detects modified routes", %{app: app} do
      # Snapshot where /api/users had different methods
      old_routes = [
        %{path: "/api/users", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]
      checksum = Drift.compute_checksum(old_routes)
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(old_routes) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert length(result.changes.modified) >= 1
    end
  end

  describe "compute_checksum/1" do
    test "same routes produce same checksum" do
      routes = [%{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      assert Drift.compute_checksum(routes) == Drift.compute_checksum(routes)
    end

    test "different routes produce different checksum" do
      r1 = [%{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      r2 = [%{path: "/b", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      assert Drift.compute_checksum(r1) != Drift.compute_checksum(r2)
    end
  end

  defp routes_to_edn(routes) do
    normalized = Enum.map(routes, fn r ->
      %{path: r.path, methods: r.methods, path_type: r.path_type, rate_limit: r.rate_limit}
    end)
    :erlang.term_to_binary(normalized) |> Base.encode64()
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger/drift_test.exs
```

- [ ] **Step 3: Implement Drift module**

```elixir
# lib/wagger/drift.ex
defmodule Wagger.Drift do
  @moduledoc """
  Detects drift between current application routes and the last generated
  WAF config snapshot for a given provider.

  Uses a fast SHA-256 checksum comparison first, then falls back to a
  structural diff when checksums don't match. Reports added, removed,
  and modified routes with impact assessment.
  """

  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Applications.Application

  defstruct [:status, :provider, :last_generated, changes: %{added: [], removed: [], modified: []}]

  @doc """
  Detects drift for the given app and provider.

  Returns a `%Drift{}` struct with:
  - `status` — `:current`, `:drifted`, or `:never_generated`
  - `provider` — the provider name
  - `last_generated` — timestamp of last snapshot (or nil)
  - `changes` ��� `%{added: [], removed: [], modified: []}` (only populated if drifted)
  """
  def detect(%Application{} = app, provider) do
    case Snapshots.latest_snapshot(app, provider) do
      nil ->
        %__MODULE__{status: :never_generated, provider: provider}

      snapshot ->
        current_routes = Routes.list_routes(app)
        current_checksum = compute_checksum(normalize_routes(current_routes))

        if current_checksum == snapshot.checksum do
          %__MODULE__{
            status: :current,
            provider: provider,
            last_generated: snapshot.inserted_at
          }
        else
          old_routes = decode_route_snapshot(snapshot.route_snapshot)
          changes = compute_diff(normalize_routes(current_routes), old_routes)

          %__MODULE__{
            status: :drifted,
            provider: provider,
            last_generated: snapshot.inserted_at,
            changes: changes
          }
        end
    end
  end

  @doc """
  Computes a SHA-256 checksum of a list of route maps (sorted by path).
  """
  def compute_checksum(routes) do
    routes
    |> Enum.sort_by(& &1[:path] || &1.path)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_routes(routes) do
    Enum.map(routes, fn r ->
      %{
        path: r.path,
        methods: r.methods || ["GET"],
        path_type: r.path_type,
        rate_limit: r.rate_limit
      }
    end)
  end

  defp decode_route_snapshot(encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defp compute_diff(current, old) do
    current_map = Map.new(current, &{&1.path, &1})
    old_map = Map.new(old, &{&1[:path], &1})

    current_paths = MapSet.new(Map.keys(current_map))
    old_paths = MapSet.new(Map.keys(old_map))

    added =
      MapSet.difference(current_paths, old_paths)
      |> Enum.map(&current_map[&1])

    removed =
      MapSet.difference(old_paths, current_paths)
      |> Enum.map(&old_map[&1])

    modified =
      MapSet.intersection(current_paths, old_paths)
      |> Enum.filter(fn path ->
        cur = current_map[path]
        old = old_map[path]
        cur.methods != (old[:methods] || old.methods) or
          cur.path_type != (old[:path_type] || old.path_type) or
          cur.rate_limit != (old[:rate_limit] || old.rate_limit)
      end)
      |> Enum.map(fn path ->
        %{path: path, current: current_map[path], previous: old_map[path]}
      end)

    %{added: added, removed: removed, modified: modified}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/drift_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/drift.ex test/wagger/drift_test.exs
git commit -m "Add drift detection with checksum fast-path and structural diff"
```

---

### Task 3: Generate Controller

**Files:**
- Create: `lib/wagger_web/controllers/generate_controller.ex`
- Create: `lib/wagger_web/controllers/generate_json.ex`
- Create: `test/wagger_web/controllers/generate_controller_test.exs`
- Modify: `lib/wagger_web/router.ex`

This is the key endpoint — it generates WAF config AND creates a snapshot.

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger_web/controllers/generate_controller_test.exs
defmodule WaggerWeb.GenerateControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100})
    {:ok, _} = Routes.create_route(app, %{path: "/health", methods: ["GET"], path_type: "exact"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn, app: app}
  end

  describe "POST /api/applications/:app_id/generate/:provider" do
    test "generates nginx config and stores snapshot", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/nginx", %{prefix: "myapp", upstream: "http://backend:8080"})
      resp = json_response(conn, 200)
      assert resp["output"] =~ "map $request_uri"
      assert resp["provider"] == "nginx"
      assert resp["snapshot_id"] != nil

      # Verify snapshot was stored
      snapshots = Snapshots.list_snapshots(app)
      assert length(snapshots) == 1
    end

    test "generates aws config", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/aws", %{prefix: "myapp", scope: "REGIONAL"})
      resp = json_response(conn, 200)
      assert resp["output"] =~ "web-acl"
      assert resp["provider"] == "aws"
    end

    test "generates cloudflare config", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/cloudflare", %{prefix: "myapp"})
      resp = json_response(conn, 200)
      assert resp["provider"] == "cloudflare"
    end

    test "rejects unknown provider", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/unknown", %{prefix: "myapp"})
      assert json_response(conn, 400)["error"] =~ "Unknown provider"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/wagger_web/controllers/generate_controller_test.exs
```

- [ ] **Step 3: Implement GenerateJSON view**

```elixir
# lib/wagger_web/controllers/generate_json.ex
defmodule WaggerWeb.GenerateJSON do
  @moduledoc false

  def show(%{output: output, provider: provider, snapshot_id: snapshot_id}) do
    %{
      output: output,
      provider: provider,
      snapshot_id: snapshot_id
    }
  end
end
```

- [ ] **Step 4: Implement GenerateController**

```elixir
# lib/wagger_web/controllers/generate_controller.ex
defmodule WaggerWeb.GenerateController do
  @moduledoc false
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Drift
  alias Wagger.Generator

  @providers %{
    "nginx" => Wagger.Generator.Nginx,
    "aws" => Wagger.Generator.Aws,
    "cloudflare" => Wagger.Generator.Cloudflare,
    "azure" => Wagger.Generator.Azure,
    "gcp" => Wagger.Generator.Gcp,
    "caddy" => Wagger.Generator.Caddy
  }

  def create(conn, %{"application_id" => app_id, "provider" => provider} = params) do
    case Map.get(@providers, provider) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})

      module ->
        app = Applications.get_application!(app_id)
        routes = Routes.list_routes(app)
        config = Map.drop(params, ["application_id", "provider"])

        case Generator.generate(module, routes, config) do
          {:ok, output} ->
            route_data = Drift.normalize_for_snapshot(routes)
            checksum = Drift.compute_checksum(route_data)

            {:ok, snapshot} =
              Snapshots.create_snapshot(%{
                application_id: app.id,
                provider: provider,
                config_params: Jason.encode!(config),
                route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
                output: output,
                checksum: checksum
              })

            render(conn, :show, output: output, provider: provider, snapshot_id: snapshot.id)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Generation failed", details: inspect(reason)})
        end
    end
  end
end
```

Note: This requires adding `normalize_for_snapshot/1` to the Drift module. Add this public function:

```elixir
# Add to lib/wagger/drift.ex
@doc "Normalizes routes for snapshot storage (strips non-essential fields)."
def normalize_for_snapshot(routes) do
  normalize_routes(routes)
end
```

Change `normalize_routes/1` from `defp` to a function called by both `detect/2` and `normalize_for_snapshot/1`.

- [ ] **Step 5: Update router**

Add to the `/api` scope in `lib/wagger_web/router.ex`:

```elixir
post "/applications/:application_id/generate/:provider", GenerateController, :create
```

- [ ] **Step 6: Run tests**

```bash
mix test test/wagger_web/controllers/generate_controller_test.exs && mix test
```

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/controllers/generate_controller.ex lib/wagger_web/controllers/generate_json.ex lib/wagger/drift.ex lib/wagger_web/router.ex test/wagger_web/controllers/generate_controller_test.exs
git commit -m "Add generate endpoint with snapshot creation"
```

---

### Task 4: Snapshot and Drift Controllers

**Files:**
- Create: `lib/wagger_web/controllers/snapshot_controller.ex`
- Create: `lib/wagger_web/controllers/snapshot_json.ex`
- Create: `lib/wagger_web/controllers/drift_controller.ex`
- Create: `lib/wagger_web/controllers/drift_json.ex`
- Create: `test/wagger_web/controllers/snapshot_controller_test.exs`
- Create: `test/wagger_web/controllers/drift_controller_test.exs`
- Modify: `lib/wagger_web/router.ex`

- [ ] **Step 1: Write failing tests for SnapshotController**

```elixir
# test/wagger_web/controllers/snapshot_controller_test.exs
defmodule WaggerWeb.SnapshotControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Snapshots

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})
    {:ok, app} = Applications.create_application(%{name: "test-app"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn, app: app}
  end

  describe "GET /api/applications/:app_id/snapshots" do
    test "lists snapshots", %{conn: conn, app: app} do
      create_snapshot(app, "nginx")
      create_snapshot(app, "aws")
      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots")
      resp = json_response(conn, 200)
      assert length(resp["data"]) == 2
    end

    test "filters by provider", %{conn: conn, app: app} do
      create_snapshot(app, "nginx")
      create_snapshot(app, "aws")
      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots?provider=nginx")
      resp = json_response(conn, 200)
      assert length(resp["data"]) == 1
    end
  end

  describe "GET /api/applications/:app_id/snapshots/:id" do
    test "shows snapshot with output", %{conn: conn, app: app} do
      {:ok, snapshot} = create_snapshot(app, "nginx")
      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots/#{snapshot.id}")
      resp = json_response(conn, 200)
      assert resp["data"]["provider"] == "nginx"
      assert resp["data"]["output"] =~ "output"
    end
  end

  defp create_snapshot(app, provider) do
    Snapshots.create_snapshot(%{
      application_id: app.id,
      provider: provider,
      config_params: "{}",
      route_snapshot: Base.encode64(:erlang.term_to_binary([])),
      output: "output-#{provider}",
      checksum: "check-#{:erlang.unique_integer()}"
    })
  end
end
```

- [ ] **Step 2: Write failing tests for DriftController**

```elixir
# test/wagger_web/controllers/drift_controller_test.exs
defmodule WaggerWeb.DriftControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Drift

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{username: "testuser"})
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET"], path_type: "exact"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    %{conn: conn, app: app}
  end

  describe "GET /api/applications/:app_id/drift/:provider" do
    test "returns never_generated when no snapshots", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")
      resp = json_response(conn, 200)
      assert resp["status"] == "never_generated"
    end

    test "returns current when routes match snapshot", %{conn: conn, app: app} do
      routes = Routes.list_routes(app)
      route_data = Drift.normalize_for_snapshot(routes)
      checksum = Drift.compute_checksum(route_data)
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")
      resp = json_response(conn, 200)
      assert resp["status"] == "current"
    end

    test "returns drifted with changes when routes differ", %{conn: conn, app: app} do
      # Snapshot with no routes
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary([]) |> Base.encode64(),
        output: "server {}",
        checksum: Drift.compute_checksum([])
      })

      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")
      resp = json_response(conn, 200)
      assert resp["status"] == "drifted"
      assert length(resp["changes"]["added"]) == 1
    end
  end
end
```

- [ ] **Step 3: Implement SnapshotController and SnapshotJSON**

```elixir
# lib/wagger_web/controllers/snapshot_controller.ex
defmodule WaggerWeb.SnapshotController do
  @moduledoc false
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Snapshots

  def index(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)
    snapshots = Snapshots.list_snapshots(app, params)
    render(conn, :index, snapshots: snapshots)
  end

  def show(conn, %{"application_id" => app_id, "id" => id}) do
    app = Applications.get_application!(app_id)
    snapshot = Snapshots.get_snapshot!(app, id)
    render(conn, :show, snapshot: snapshot)
  end
end
```

```elixir
# lib/wagger_web/controllers/snapshot_json.ex
defmodule WaggerWeb.SnapshotJSON do
  @moduledoc false

  def index(%{snapshots: snapshots}) do
    %{data: Enum.map(snapshots, &summary/1)}
  end

  def show(%{snapshot: snapshot}) do
    %{data: detail(snapshot)}
  end

  defp summary(s) do
    %{id: s.id, provider: s.provider, checksum: s.checksum, inserted_at: s.inserted_at}
  end

  defp detail(s) do
    %{id: s.id, provider: s.provider, config_params: s.config_params,
      output: s.output, checksum: s.checksum, inserted_at: s.inserted_at}
  end
end
```

- [ ] **Step 4: Implement DriftController and DriftJSON**

```elixir
# lib/wagger_web/controllers/drift_controller.ex
defmodule WaggerWeb.DriftController do
  @moduledoc false
  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Drift

  def show(conn, %{"application_id" => app_id, "provider" => provider}) do
    app = Applications.get_application!(app_id)
    result = Drift.detect(app, provider)
    render(conn, :show, drift: result)
  end
end
```

```elixir
# lib/wagger_web/controllers/drift_json.ex
defmodule WaggerWeb.DriftJSON do
  @moduledoc false

  def show(%{drift: drift}) do
    base = %{
      provider: drift.provider,
      status: Atom.to_string(drift.status),
      last_generated: drift.last_generated
    }

    if drift.status == :drifted do
      Map.put(base, :changes, %{
        added: Enum.map(drift.changes.added, &route_summary/1),
        removed: Enum.map(drift.changes.removed, &route_summary/1),
        modified: Enum.map(drift.changes.modified, &modified_summary/1)
      })
    else
      base
    end
  end

  defp route_summary(route) do
    %{path: route[:path] || route.path, methods: route[:methods] || route.methods}
  end

  defp modified_summary(mod) do
    %{path: mod.path, current: route_summary(mod.current), previous: route_summary(mod.previous)}
  end
end
```

- [ ] **Step 5: Update router**

Add to the `/api` scope in `lib/wagger_web/router.ex`:

```elixir
get "/applications/:application_id/snapshots", SnapshotController, :index
get "/applications/:application_id/snapshots/:id", SnapshotController, :show
get "/applications/:application_id/drift/:provider", DriftController, :show
```

- [ ] **Step 6: Run all tests**

```bash
mix test test/wagger_web/controllers/snapshot_controller_test.exs test/wagger_web/controllers/drift_controller_test.exs && mix test
```

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/controllers/snapshot_controller.ex lib/wagger_web/controllers/snapshot_json.ex lib/wagger_web/controllers/drift_controller.ex lib/wagger_web/controllers/drift_json.ex lib/wagger_web/router.ex test/wagger_web/controllers/snapshot_controller_test.exs test/wagger_web/controllers/drift_controller_test.exs
git commit -m "Add snapshot history and drift detection API endpoints"
```

---

### Task 5: End-to-End Verification

No new files. Test the full flow: generate → snapshot stored → modify routes → detect drift.

- [ ] **Step 1: Start server and create test data**

```bash
mix run -e '{:ok, _, key} = Wagger.Accounts.create_user(%{username: "admin"}); File.write!("/tmp/wagger_key", key)'
```

- [ ] **Step 2: Create app and routes, generate config**

```bash
API_KEY=$(cat /tmp/wagger_key)
# Create app
curl -s -X POST http://localhost:4000/api/applications -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"name": "demo"}'
# Import routes
curl -s -X POST http://localhost:4000/api/applications/1/import/bulk -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"body": "GET /api/users\nPOST /api/items"}' > /tmp/preview.json
curl -s -X POST http://localhost:4000/api/applications/1/import/confirm -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d @/tmp/preview.json
# Generate nginx config
curl -s -X POST http://localhost:4000/api/applications/1/generate/nginx -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"prefix": "demo", "upstream": "http://backend:8080"}'
```

- [ ] **Step 3: Check drift (should be current)**

```bash
curl -s http://localhost:4000/api/applications/1/drift/nginx -H "Authorization: Bearer $API_KEY" | python3 -m json.tool
```

Expected: `"status": "current"`

- [ ] **Step 4: Add a new route and check drift again**

```bash
curl -s -X POST http://localhost:4000/api/applications/1/routes -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"path": "/api/new", "methods": ["GET"], "path_type": "exact"}'
curl -s http://localhost:4000/api/applications/1/drift/nginx -H "Authorization: Bearer $API_KEY" | python3 -m json.tool
```

Expected: `"status": "drifted"`, with `/api/new` in `changes.added`

- [ ] **Step 5: View snapshot history**

```bash
curl -s http://localhost:4000/api/applications/1/snapshots -H "Authorization: Bearer $API_KEY" | python3 -m json.tool
```

Expected: 1 snapshot entry with provider "nginx"

- [ ] **Step 6: Commit any fixes**

```bash
git add -u && git commit -m "Fix issues found during snapshots/drift e2e verification"
```
