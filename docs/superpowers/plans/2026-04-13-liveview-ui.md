# LiveView UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Wagger LiveView UI: dashboard with progressive disclosure, SwaggerUI-style app detail with inline provider configs, and user management. Tokyo Night theme.

**Architecture:** Three LiveView pages (dashboard, app detail, users) sharing a common layout with minimal nav. Function components for reusable UI pieces (status cards, endpoint rows, provider sections). DaisyUI custom theme for Tokyo Night palette. LiveView contexts call the same domain modules the API controllers do.

**Tech Stack:** Phoenix 1.8 LiveView, Tailwind CSS, DaisyUI, Heroicons

---

## File Structure

```
assets/css/
  app.css                          — add Tokyo Night DaisyUI theme
lib/wagger_web/
  components/
    layouts/
      app.html.heex                — app layout with Tokyo Night nav
    wagger_components.ex           — status_card, method_pill, endpoint_row, provider_section, drift_diff, import_section
  live/
    dashboard_live.ex              — status bar + filtered app cards
    dashboard_live.html.heex       — dashboard template
    app_detail_live.ex             — route display + provider configs + import
    app_detail_live.html.heex      — app detail template
    user_live.ex                   — user CRUD
    user_live.html.heex            — user management template
  router.ex                        — add live routes
test/wagger_web/live/
  dashboard_live_test.exs
  app_detail_live_test.exs
  user_live_test.exs
```

## Existing Infrastructure

- All domain logic exists: `Wagger.Applications`, `Wagger.Routes`, `Wagger.Snapshots`, `Wagger.Drift`, `Wagger.Generator`, `Wagger.Import.*`, `Wagger.Accounts`
- DaisyUI + Tailwind are configured in `assets/css/app.css`
- Root layout at `lib/wagger_web/components/layouts/root.html.heex`
- `CoreComponents` at `lib/wagger_web/components/core_components.ex` provides forms, tables, inputs
- Router has browser pipeline with session/CSRF. API pipeline has auth. Browser pipeline does NOT have auth — LiveView needs its own session-based auth or we skip auth for the UI initially.

## Auth Decision for LiveView

The browser pipeline currently has no authentication. Adding session-based auth to LiveView requires login forms and session management — that's Plan 6 territory (deferred). For now, the LiveView UI is **unauthenticated** (accessible without login). This is fine for home lab / self-hosted use behind a VPN. The API remains key-authenticated.

---

### Task 1: Tokyo Night Theme

**Files:**
- Modify: `assets/css/app.css`

- [ ] **Step 1: Replace the dark DaisyUI theme with Tokyo Night**

In `assets/css/app.css`, find the `@plugin "../vendor/daisyui-theme"` block with `name: "dark"` and replace it with a Tokyo Night theme. The theme uses DaisyUI's OKLCH color format. Convert the Tokyo Night hex values to OKLCH.

Key Tokyo Night hex → OKLCH mappings:
- `#1a1b26` (base bg) → `oklch(18.5% 0.015 262)`
- `#292e42` (surface) → `oklch(24% 0.02 260)`
- `#16161e` (darker surface) → `oklch(15.5% 0.012 265)`
- `#c0caf5` (text primary) → `oklch(83% 0.06 270)`
- `#a9b1d6` (text secondary) → `oklch(75% 0.04 265)`
- `#7aa2f7` (primary/accent blue) → `oklch(68% 0.15 255)`
- `#9ece6a` (success green) → `oklch(80% 0.16 135)`
- `#e0af68` (warning amber) → `oklch(78% 0.12 75)`
- `#f7768e` (error red) → `oklch(68% 0.17 15)`
- `#bb9af7` (accent purple) → `oklch(72% 0.15 295)`

Replace the dark theme block:

```css
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: false;
  prefersdark: true;
  color-scheme: "dark";
  --color-base-100: oklch(18.5% 0.015 262);
  --color-base-200: oklch(15.5% 0.012 265);
  --color-base-300: oklch(24% 0.02 260);
  --color-base-content: oklch(75% 0.04 265);
  --color-primary: oklch(68% 0.15 255);
  --color-primary-content: oklch(95% 0.01 260);
  --color-secondary: oklch(72% 0.15 295);
  --color-secondary-content: oklch(95% 0.01 290);
  --color-accent: oklch(68% 0.15 255);
  --color-accent-content: oklch(95% 0.01 260);
  --color-neutral: oklch(24% 0.02 260);
  --color-neutral-content: oklch(83% 0.06 270);
  --color-info: oklch(68% 0.15 255);
  --color-info-content: oklch(95% 0.01 260);
  --color-success: oklch(80% 0.16 135);
  --color-success-content: oklch(18.5% 0.015 262);
  --color-warning: oklch(78% 0.12 75);
  --color-warning-content: oklch(18.5% 0.015 262);
  --color-error: oklch(68% 0.17 15);
  --color-error-content: oklch(95% 0.01 10);
  --radius-selector: 0.375rem;
  --radius-field: 0.375rem;
  --radius-box: 0.5rem;
  --size-selector: 0.25rem;
  --size-field: 0.25rem;
  --border: 1px;
  --depth: 0;
  --noise: 0;
}
```

Also add custom CSS variables for Tokyo Night-specific colors below the theme blocks:

```css
/* Tokyo Night specific colors not covered by DaisyUI semantics */
:root[data-theme="dark"] {
  --tn-text-muted: oklch(44% 0.04 260);
  --tn-border-subtle: oklch(28% 0.02 258);
  --tn-method-get: #9ece6a;
  --tn-method-post: #7aa2f7;
  --tn-method-put: #e0af68;
  --tn-method-delete: #f7768e;
  --tn-method-other: #565f89;
  --tn-param: #bb9af7;
}
```

- [ ] **Step 2: Verify theme compiles**

```bash
mix assets.build
```

Expected: builds without errors.

- [ ] **Step 3: Commit**

```bash
git add assets/css/app.css
git commit -m "Add Tokyo Night DaisyUI theme"
```

---

### Task 2: App Layout and Navigation

**Files:**
- Create: `lib/wagger_web/components/layouts/app.html.heex`
- Modify: `lib/wagger_web/router.ex`

- [ ] **Step 1: Create the app layout**

The app layout wraps all LiveView pages with the Tokyo Night nav bar.

```heex
<%!-- lib/wagger_web/components/layouts/app.html.heex --%>
<div class="min-h-screen bg-base-100 font-mono">
  <nav class="bg-base-200 border-b border-neutral px-4 py-2.5 flex items-center justify-between">
    <div class="flex items-center gap-6">
      <.link navigate={~p"/"} class="text-primary font-bold text-lg">wagger</.link>
      <div class="flex items-center gap-4 text-sm">
        <.link navigate={~p"/"} class={"#{if @active_nav == :dashboard, do: "text-base-content", else: "text-[var(--tn-text-muted)] hover:text-base-content"}"}>
          Dashboard
        </.link>
        <.link navigate={~p"/users"} class={"#{if @active_nav == :users, do: "text-base-content", else: "text-[var(--tn-text-muted)] hover:text-base-content"}"}>
          Users
        </.link>
      </div>
    </div>
    <span class="text-sm text-[var(--tn-text-muted)]">wagger</span>
  </nav>
  <main class="p-4">
    <.flash_group flash={@flash} />
    {@inner_content}
  </main>
</div>
```

- [ ] **Step 2: Add live routes to the router**

Update `lib/wagger_web/router.ex`. Add a new live session scope inside the browser pipeline:

```elixir
scope "/", WaggerWeb do
  pipe_through :browser

  live_session :default, on_mount: [{WaggerWeb.Hooks.NavHook, :default}] do
    live "/", DashboardLive, :index
    live "/applications/:id", AppDetailLive, :show
    live "/users", UserLive, :index
  end
end
```

Remove or keep the existing `get "/", PageController, :home` — replace it with the live route.

- [ ] **Step 3: Create the NavHook**

Create `lib/wagger_web/hooks/nav_hook.ex`:

```elixir
defmodule WaggerWeb.Hooks.NavHook do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :active_nav, :dashboard)}
  end
end
```

- [ ] **Step 4: Verify compilation**

```bash
mix compile
```

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/components/layouts/app.html.heex lib/wagger_web/router.ex lib/wagger_web/hooks/nav_hook.ex
git commit -m "Add Tokyo Night app layout with navigation"
```

---

### Task 3: Wagger Components

**Files:**
- Create: `lib/wagger_web/components/wagger_components.ex`

Create the shared function components used across LiveViews. This is a large file but each component is a small, independent function.

- [ ] **Step 1: Create the component module**

```elixir
defmodule WaggerWeb.WaggerComponents do
  @moduledoc """
  Wagger-specific UI components: status cards, method pills, endpoint rows,
  provider sections, drift diffs, and import area.
  """
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  # --- Status Card (Dashboard) ---

  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :status, :atom, required: true
  attr :selected, :boolean, default: false
  attr :dimmed, :boolean, default: false

  def status_card(assigns) do
    ~H"""
    <div
      phx-click="filter_status"
      phx-value-status={@status}
      class={"flex-1 rounded-lg p-4 text-center cursor-pointer border-2 transition-all
        #{status_card_colors(@status)}
        #{if @selected, do: "shadow-lg shadow-current/20", else: ""}
        #{if @dimmed, do: "opacity-40", else: ""}"}
    >
      <div class="text-3xl font-bold"><%= @count %></div>
      <div class="text-xs text-[var(--tn-text-muted)]"><%= @label %></div>
      <%= if @selected do %>
        <div class="text-[10px] mt-1">&#9660; showing</div>
      <% end %>
    </div>
    """
  end

  defp status_card_colors(:drifted), do: "border-warning text-warning bg-base-300"
  defp status_card_colors(:current), do: "border-success text-success bg-base-300"
  defp status_card_colors(:never_generated), do: "border-neutral text-[var(--tn-text-muted)] bg-base-300"

  # --- Method Pill ---

  attr :method, :string, required: true

  def method_pill(assigns) do
    ~H"""
    <span class={"inline-block px-2 py-0.5 rounded text-xs font-bold min-w-[52px] text-center
      #{method_pill_color(@method)}"}>
      <%= @method %>
    </span>
    """
  end

  defp method_pill_color("GET"), do: "bg-[var(--tn-method-get)] text-base-100"
  defp method_pill_color("POST"), do: "bg-[var(--tn-method-post)] text-base-100"
  defp method_pill_color("PUT"), do: "bg-[var(--tn-method-put)] text-base-100"
  defp method_pill_color("PATCH"), do: "bg-[var(--tn-method-put)] text-base-100"
  defp method_pill_color("DELETE"), do: "bg-[var(--tn-method-delete)] text-base-100"
  defp method_pill_color(_), do: "bg-[var(--tn-method-other)] text-base-content"

  # --- Provider Badge ---

  attr :provider, :string, required: true
  attr :status, :atom, required: true
  attr :summary, :string, default: nil
  attr :dimmed, :boolean, default: false

  def provider_badge(assigns) do
    ~H"""
    <span class={"inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs
      #{provider_badge_style(@status)}
      #{if @dimmed, do: "opacity-40", else: ""}
      cursor-pointer"}>
      <span class="font-semibold"><%= @provider %></span>
      <%= if @summary do %>
        <span>: <%= @summary %></span>
      <% end %>
    </span>
    """
  end

  defp provider_badge_style(:drifted), do: "bg-warning text-base-100 font-bold"
  defp provider_badge_style(:current), do: "bg-base-300 text-success border border-neutral"
  defp provider_badge_style(:never_generated), do: "bg-base-300 text-[var(--tn-text-muted)] border border-neutral"

  # --- Drift Diff ---

  attr :changes, :map, required: true

  def drift_diff(assigns) do
    ~H"""
    <div class="text-sm space-y-0.5">
      <%= for route <- @changes.added do %>
        <div class="text-success">
          + <%= route[:path] || route.path %>
          <span class="opacity-50"><%= Enum.join(route[:methods] || route.methods, ", ") %></span>
        </div>
      <% end %>
      <%= for route <- @changes.removed do %>
        <div class="text-error">
          - <%= route[:path] || route.path %>
          <span class="opacity-50"><%= Enum.join(route[:methods] || route.methods, ", ") %></span>
        </div>
      <% end %>
      <%= for mod <- @changes.modified do %>
        <div class="text-warning">
          ~ <%= mod.path %>
          <span class="opacity-50">changed</span>
        </div>
      <% end %>
    </div>
    """
  end
end
```

- [ ] **Step 2: Import into WaggerWeb html_helpers**

In `lib/wagger_web.ex`, inside the `html_helpers` function, add:

```elixir
import WaggerWeb.WaggerComponents
```

- [ ] **Step 3: Verify compilation**

```bash
mix compile
```

- [ ] **Step 4: Commit**

```bash
git add lib/wagger_web/components/wagger_components.ex lib/wagger_web.ex
git commit -m "Add Wagger UI components: status cards, method pills, provider badges, drift diff"
```

---

### Task 4: Dashboard LiveView

**Files:**
- Create: `lib/wagger_web/live/dashboard_live.ex`
- Create: `lib/wagger_web/live/dashboard_live.html.heex`
- Create: `test/wagger_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger_web/live/dashboard_live_test.exs
defmodule WaggerWeb.DashboardLiveTest do
  use WaggerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Drift

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app", tags: ["api"]})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET"], path_type: "exact"})
    %{app: app}
  end

  test "renders status summary cards", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "never"
    assert html =~ "wagger"
  end

  test "shows app cards when status is clicked", %{conn: conn, app: app} do
    # Create a snapshot so we have a "current" status
    routes = Routes.list_routes(app)
    route_data = Drift.normalize_for_snapshot(routes)
    checksum = Drift.compute_checksum(route_data)
    Snapshots.create_snapshot(%{
      application_id: app.id, provider: "nginx",
      route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
      output: "server {}", checksum: checksum
    })

    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element("[phx-value-status=current]") |> render_click()
    assert html =~ "test-app"
  end

  test "navigates to app detail on app name click", %{conn: conn, app: app} do
    {:ok, view, _html} = live(conn, ~p"/")
    # Click never_generated to show the app
    view |> element("[phx-value-status=never_generated]") |> render_click()
    assert has_element?(view, "[data-app-id=\"#{app.id}\"]")
  end
end
```

- [ ] **Step 2: Implement DashboardLive**

```elixir
# lib/wagger_web/live/dashboard_live.ex
defmodule WaggerWeb.DashboardLive do
  @moduledoc false
  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift

  @providers ~w(nginx aws cloudflare azure gcp caddy)

  @impl true
  def mount(_params, _session, socket) do
    apps = Applications.list_applications()
    drift_data = compute_all_drift(apps)

    socket =
      socket
      |> assign(:active_nav, :dashboard)
      |> assign(:apps, apps)
      |> assign(:drift_data, drift_data)
      |> assign(:status_filter, nil)
      |> assign(:page_title, "Dashboard")

    {:ok, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    current = socket.assigns.status_filter
    new_filter = if current == status, do: nil, else: status
    {:noreply, assign(socket, :status_filter, new_filter)}
  end

  def status_counts(drift_data) do
    Enum.reduce(drift_data, %{drifted: 0, current: 0, never_generated: 0}, fn {_app_id, providers}, acc ->
      Enum.reduce(providers, acc, fn {_provider, drift}, inner_acc ->
        Map.update!(inner_acc, drift.status, &(&1 + 1))
      end)
    end)
  end

  def filtered_apps(apps, drift_data, nil), do: []

  def filtered_apps(apps, drift_data, status_filter) do
    status_atom = String.to_existing_atom(status_filter)

    apps
    |> Enum.filter(fn app ->
      providers = Map.get(drift_data, app.id, %{})
      Enum.any?(providers, fn {_p, drift} -> drift.status == status_atom end)
    end)
    |> Enum.sort_by(fn app ->
      providers = Map.get(drift_data, app.id, %{})
      drifted_count = Enum.count(providers, fn {_p, d} -> d.status == :drifted end)
      -drifted_count
    end)
  end

  def app_provider_drifts(drift_data, app_id) do
    Map.get(drift_data, app_id, %{})
  end

  defp compute_all_drift(apps) do
    Map.new(apps, fn app ->
      providers =
        Map.new(@providers, fn provider ->
          {provider, Drift.detect(app, provider)}
        end)

      {app.id, providers}
    end)
  end
end
```

- [ ] **Step 3: Create the dashboard template**

```heex
<%!-- lib/wagger_web/live/dashboard_live.html.heex --%>
<div>
  <%!-- Status summary bar --%>
  <% counts = status_counts(@drift_data) %>
  <div class="flex gap-4 mb-6">
    <.status_card
      count={counts.drifted}
      label="drifted"
      status={:drifted}
      selected={@status_filter == "drifted"}
      dimmed={@status_filter != nil and @status_filter != "drifted"}
    />
    <.status_card
      count={counts.current}
      label="current"
      status={:current}
      selected={@status_filter == "current"}
      dimmed={@status_filter != nil and @status_filter != "current"}
    />
    <.status_card
      count={counts.never_generated}
      label="never generated"
      status={:never_generated}
      selected={@status_filter == "never_generated"}
      dimmed={@status_filter != nil and @status_filter != "never_generated"}
    />
  </div>

  <%!-- App cards --%>
  <%= if @status_filter == nil do %>
    <div class="text-center text-[var(--tn-text-muted)] py-16 text-sm">
      Click a status above to see affected applications
    </div>
  <% else %>
    <div class="space-y-3">
      <%= for app <- filtered_apps(@apps, @drift_data, @status_filter) do %>
        <div
          data-app-id={app.id}
          class={"rounded-lg p-4 bg-base-300 border-l-4
            #{app_card_border_class(app_provider_drifts(@drift_data, app.id))}"}
        >
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-3">
              <.link navigate={~p"/applications/#{app.id}"} class="font-bold text-neutral-content hover:text-primary">
                <%= app.name %>
              </.link>
              <span class="text-[var(--tn-text-muted)] text-sm"><%= length_routes(app) %> routes</span>
              <%= for tag <- (app.tags || []) do %>
                <span class="bg-neutral text-[var(--tn-text-muted)] px-1.5 py-0.5 rounded text-[10px]"><%= tag %></span>
              <% end %>
            </div>
          </div>
          <div class="flex gap-1.5 flex-wrap">
            <%= for {provider, drift} <- app_provider_drifts(@drift_data, app.id) do %>
              <%= if drift.status != :never_generated or @status_filter == "never_generated" do %>
                <.provider_badge
                  provider={provider}
                  status={drift.status}
                  summary={drift_summary(drift)}
                  dimmed={Atom.to_string(drift.status) != @status_filter}
                />
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 4: Add helper functions to the LiveView module**

Add these at the bottom of `dashboard_live.ex`:

```elixir
  def length_routes(app) do
    length(Wagger.Routes.list_routes(app))
  end

  def drift_summary(%{status: :current}), do: "current"
  def drift_summary(%{status: :never_generated}), do: nil
  def drift_summary(%{status: :drifted, changes: changes}) do
    parts = []
    parts = if length(changes.added) > 0, do: parts ++ ["+#{length(changes.added)}"], else: parts
    parts = if length(changes.removed) > 0, do: parts ++ ["-#{length(changes.removed)}"], else: parts
    parts = if length(changes.modified) > 0, do: parts ++ ["~#{length(changes.modified)}"], else: parts
    Enum.join(parts, " ")
  end

  def app_card_border_class(providers) do
    has_removed = Enum.any?(providers, fn {_, d} ->
      d.status == :drifted and length(Map.get(d.changes, :removed, [])) > 0
    end)
    has_drifted = Enum.any?(providers, fn {_, d} -> d.status == :drifted end)

    cond do
      has_removed -> "border-error"
      has_drifted -> "border-warning"
      true -> "border-neutral"
    end
  end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/wagger_web/live/dashboard_live_test.exs && mix test
```

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/live/ test/wagger_web/live/
git commit -m "Add Dashboard LiveView with status summary and app cards"
```

---

### Task 5: App Detail LiveView — Route Display

**Files:**
- Create: `lib/wagger_web/live/app_detail_live.ex`
- Create: `lib/wagger_web/live/app_detail_live.html.heex`
- Create: `test/wagger_web/live/app_detail_live_test.exs`

This task builds the app detail page with the SwaggerUI-style route display. Provider sections and import are added in Tasks 6 and 7.

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger_web/live/app_detail_live_test.exs
defmodule WaggerWeb.AppDetailLiveTest do
  use WaggerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Wagger.Applications
  alias Wagger.Routes

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app", tags: ["api"]})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "List and create users"})
    {:ok, _} = Routes.create_route(app, %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", description: "User detail"})
    {:ok, _} = Routes.create_route(app, %{path: "/health", methods: ["GET"], path_type: "exact", description: "Health check"})
    %{app: app}
  end

  test "renders app name and route count", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/applications/#{app.id}")
    assert html =~ "test-app"
    assert html =~ "3 routes"
  end

  test "displays routes with method pills", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/applications/#{app.id}")
    assert html =~ "GET"
    assert html =~ "POST"
    assert html =~ "DELETE"
    assert html =~ "/api/users"
    assert html =~ "/health"
  end

  test "groups routes by common prefix", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/applications/#{app.id}")
    assert html =~ "/api/users"
  end

  test "shows rate limit when present", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/applications/#{app.id}")
    assert html =~ "100/min"
  end

  test "highlights path parameters", %{conn: conn, app: app} do
    {:ok, _view, html} = live(conn, ~p"/applications/#{app.id}")
    assert html =~ "{id}"
  end
end
```

- [ ] **Step 2: Implement AppDetailLive**

```elixir
# lib/wagger_web/live/app_detail_live.ex
defmodule WaggerWeb.AppDetailLive do
  @moduledoc false
  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Drift

  @providers ~w(nginx aws cloudflare azure gcp caddy)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    app = Applications.get_application!(id)
    routes = Routes.list_routes(app)
    grouped = group_routes(routes)
    drifts = compute_drifts(app)

    socket =
      socket
      |> assign(:active_nav, nil)
      |> assign(:app, app)
      |> assign(:routes, routes)
      |> assign(:grouped_routes, grouped)
      |> assign(:drifts, drifts)
      |> assign(:expanded_providers, auto_expand_drifted(drifts))
      |> assign(:show_import, false)
      |> assign(:page_title, app.name)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_provider", %{"provider" => provider}, socket) do
    expanded = socket.assigns.expanded_providers
    new_expanded =
      if MapSet.member?(expanded, provider),
        do: MapSet.delete(expanded, provider),
        else: MapSet.put(expanded, provider)
    {:noreply, assign(socket, :expanded_providers, new_expanded)}
  end

  @impl true
  def handle_event("toggle_import", _, socket) do
    {:noreply, assign(socket, :show_import, !socket.assigns.show_import)}
  end

  def group_routes(routes) do
    routes
    |> expand_methods()
    |> Enum.group_by(&route_group_key/1)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp expand_methods(routes) do
    Enum.flat_map(routes, fn route ->
      Enum.map(route.methods, fn method ->
        %{route: route, method: method}
      end)
    end)
  end

  defp route_group_key(%{route: route}) do
    parts = String.split(route.path, "/", trim: true)
    case parts do
      [first, second | _] -> "/#{first}/#{second}"
      [first] -> "other"
      [] -> "other"
    end
  end

  defp compute_drifts(app) do
    Map.new(@providers, fn provider ->
      {provider, Drift.detect(app, provider)}
    end)
  end

  defp auto_expand_drifted(drifts) do
    drifts
    |> Enum.filter(fn {_p, d} -> d.status == :drifted end)
    |> Enum.map(fn {p, _d} -> p end)
    |> MapSet.new()
  end

  def format_path(path) do
    # Split path into segments, wrap {param} in a span
    path
    |> String.split(~r/(\{[^}]+\})/)
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "{") do
        {"param", segment}
      else
        {"path", segment}
      end
    end)
  end
end
```

- [ ] **Step 3: Create the template**

```heex
<%!-- lib/wagger_web/live/app_detail_live.html.heex --%>
<div>
  <%!-- App header --%>
  <div class="border-b border-neutral pb-4 mb-4">
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-bold text-neutral-content"><%= @app.name %></h1>
        <span class="text-[var(--tn-text-muted)] text-sm"><%= length(@routes) %> routes</span>
        <%= for tag <- (@app.tags || []) do %>
          <span class="bg-neutral text-[var(--tn-text-muted)] px-1.5 py-0.5 rounded text-[10px]"><%= tag %></span>
        <% end %>
      </div>
      <div class="flex gap-1.5">
        <%= for {provider, drift} <- @drifts do %>
          <%= if drift.status != :never_generated do %>
            <.provider_badge
              provider={provider}
              status={drift.status}
              summary={drift_summary(drift)}
            />
          <% end %>
        <% end %>
      </div>
    </div>
  </div>

  <%!-- Route display --%>
  <div class="mb-6">
    <div class="text-xs text-[var(--tn-text-muted)] uppercase tracking-wider mb-2">Routes</div>
    <%= for {group, endpoints} <- @grouped_routes do %>
      <div class="mb-1">
        <div class="text-xs text-[var(--tn-text-muted)] py-1.5 border-b border-[var(--tn-border-subtle)]">
          <span class="text-primary"><%= group %></span>
          <span class="text-neutral ml-1">&mdash; <%= length(endpoints) %> endpoints</span>
        </div>
        <%= for ep <- endpoints do %>
          <div class="flex items-center gap-2.5 py-1.5 pl-3 border-b border-base-100 text-sm">
            <.method_pill method={ep.method} />
            <span class="text-neutral-content">
              <%= for {type, segment} <- format_path(ep.route.path) do %>
                <%= if type == "param" do %>
                  <span class="text-secondary"><%= segment %></span>
                <% else %>
                  <%= segment %>
                <% end %>
              <% end %>
            </span>
            <span class="text-[var(--tn-text-muted)] text-xs ml-auto"><%= ep.route.description %></span>
            <%= if ep.route.rate_limit do %>
              <span class="text-[var(--tn-text-muted)] text-[10px] bg-base-300 px-1.5 py-0.5 rounded"><%= ep.route.rate_limit %>/min</span>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
  </div>

  <%!-- Provider config sections --%>
  <div class="space-y-3 mb-6">
    <%= for {provider, drift} <- @drifts, drift.status != :never_generated do %>
      <div class={"rounded-lg bg-base-300 border #{if drift.status == :drifted, do: "border-warning", else: "border-neutral"}"}>
        <div
          phx-click="toggle_provider"
          phx-value-provider={provider}
          class="px-4 py-3 flex items-center justify-between cursor-pointer"
        >
          <div>
            <span class={"font-bold #{if drift.status == :drifted, do: "text-warning", else: "text-success"}"}><%= String.capitalize(provider) %></span>
            <span class="text-[var(--tn-text-muted)] text-xs ml-2">
              <%= if drift.status == :drifted do %>
                <%= drift_summary(drift) %> since last generation
              <% else %>
                current &mdash; <%= drift.last_generated %>
              <% end %>
            </span>
          </div>
          <span class="text-[var(--tn-text-muted)] text-xs">
            <%= if MapSet.member?(@expanded_providers, provider), do: "&#9660;", else: "&#9654;" %>
          </span>
        </div>
        <%= if MapSet.member?(@expanded_providers, provider) do %>
          <div class="px-4 pb-4 border-t border-neutral">
            <%= if drift.status == :drifted do %>
              <div class="py-3">
                <.drift_diff changes={drift.changes} />
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
  </div>

  <%!-- Import section (collapsed) --%>
  <div class="rounded-lg bg-base-300 border border-neutral">
    <div
      phx-click="toggle_import"
      class="px-4 py-3 flex items-center justify-between cursor-pointer"
    >
      <span class="text-[var(--tn-text-muted)]">Import routes...</span>
      <span class="text-[var(--tn-text-muted)] text-xs">
        <%= if @show_import, do: "&#9660;", else: "&#9654;" %>
      </span>
    </div>
  </div>
</div>
```

Add the `drift_summary` helper to `app_detail_live.ex` (same logic as dashboard):

```elixir
  def drift_summary(%{status: :current}), do: "current"
  def drift_summary(%{status: :never_generated}), do: nil
  def drift_summary(%{status: :drifted, changes: changes}) do
    parts = []
    parts = if length(changes.added) > 0, do: parts ++ ["+#{length(changes.added)} added"], else: parts
    parts = if length(changes.removed) > 0, do: parts ++ ["-#{length(changes.removed)} removed"], else: parts
    parts = if length(changes.modified) > 0, do: parts ++ ["~#{length(changes.modified)} modified"], else: parts
    Enum.join(parts, ", ")
  end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger_web/live/app_detail_live_test.exs && mix test
```

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/live/app_detail_live.ex lib/wagger_web/live/app_detail_live.html.heex test/wagger_web/live/app_detail_live_test.exs
git commit -m "Add App Detail LiveView with SwaggerUI-style route display and provider sections"
```

---

### Task 6: User Management LiveView

**Files:**
- Create: `lib/wagger_web/live/user_live.ex`
- Create: `lib/wagger_web/live/user_live.html.heex`
- Create: `test/wagger_web/live/user_live_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/wagger_web/live/user_live_test.exs
defmodule WaggerWeb.UserLiveTest do
  use WaggerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Wagger.Accounts

  test "renders user list", %{conn: conn} do
    {:ok, _, _} = Accounts.create_user(%{username: "alice", display_name: "Alice"})
    {:ok, _view, html} = live(conn, ~p"/users")
    assert html =~ "alice"
    assert html =~ "Alice"
  end

  test "creates a new user and shows API key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")
    html =
      view
      |> form("#create-user-form", %{username: "bob", display_name: "Bob"})
      |> render_submit()

    assert html =~ "bob"
    # The API key should be displayed once
    assert html =~ "API Key"
  end

  test "shows Users nav as active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/users")
    assert html =~ "Users"
  end
end
```

- [ ] **Step 2: Implement UserLive**

```elixir
# lib/wagger_web/live/user_live.ex
defmodule WaggerWeb.UserLive do
  @moduledoc false
  use WaggerWeb, :live_view

  alias Wagger.Accounts

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_users()

    socket =
      socket
      |> assign(:active_nav, :users)
      |> assign(:users, users)
      |> assign(:new_api_key, nil)
      |> assign(:page_title, "Users")

    {:ok, socket}
  end

  @impl true
  def handle_event("create_user", %{"username" => username, "display_name" => display_name}, socket) do
    case Accounts.create_user(%{username: username, display_name: display_name}) do
      {:ok, _user, api_key} ->
        users = Accounts.list_users()
        {:noreply,
          socket
          |> assign(:users, users)
          |> assign(:new_api_key, api_key)
          |> put_flash(:info, "User created")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("dismiss_key", _, socket) do
    {:noreply, assign(socket, :new_api_key, nil)}
  end

  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, _} = Accounts.delete_user(user)
    {:noreply, assign(socket, :users, Accounts.list_users())}
  end
end
```

This requires adding `list_users/0`, `get_user!/1`, and `delete_user/1` to `Wagger.Accounts`. Add them:

```elixir
# Add to lib/wagger/accounts.ex

def list_users do
  Repo.all(User)
end

def get_user!(id), do: Repo.get!(User, id)

def delete_user(%User{} = user) do
  Repo.delete(user)
end
```

- [ ] **Step 3: Create the template**

```heex
<%!-- lib/wagger_web/live/user_live.html.heex --%>
<div>
  <h1 class="text-xl font-bold text-neutral-content mb-4">Users</h1>

  <%!-- API Key alert --%>
  <%= if @new_api_key do %>
    <div class="bg-base-300 border border-warning rounded-lg p-4 mb-4">
      <div class="flex items-center justify-between mb-2">
        <span class="font-bold text-warning text-sm">API Key (shown once — copy it now)</span>
        <button phx-click="dismiss_key" class="text-[var(--tn-text-muted)] text-xs hover:text-base-content">dismiss</button>
      </div>
      <code class="text-neutral-content text-sm bg-base-100 px-3 py-1.5 rounded block font-mono select-all"><%= @new_api_key %></code>
    </div>
  <% end %>

  <%!-- Create user form --%>
  <div class="bg-base-300 rounded-lg p-4 mb-6 border border-neutral">
    <form id="create-user-form" phx-submit="create_user" class="flex items-end gap-3">
      <div>
        <label class="text-xs text-[var(--tn-text-muted)] block mb-1">Username</label>
        <input name="username" type="text" required
          class="bg-base-100 border border-neutral rounded px-2 py-1.5 text-sm text-base-content font-mono focus:border-primary focus:outline-none" />
      </div>
      <div>
        <label class="text-xs text-[var(--tn-text-muted)] block mb-1">Display Name</label>
        <input name="display_name" type="text"
          class="bg-base-100 border border-neutral rounded px-2 py-1.5 text-sm text-base-content font-mono focus:border-primary focus:outline-none" />
      </div>
      <button type="submit" class="bg-primary text-primary-content px-4 py-1.5 rounded text-sm font-bold hover:opacity-90">
        Create User
      </button>
    </form>
  </div>

  <%!-- User table --%>
  <div class="bg-base-300 rounded-lg border border-neutral">
    <table class="w-full text-sm">
      <thead>
        <tr class="border-b border-neutral text-[var(--tn-text-muted)] text-xs uppercase tracking-wider">
          <th class="text-left px-4 py-2">Username</th>
          <th class="text-left px-4 py-2">Display Name</th>
          <th class="text-left px-4 py-2">Created</th>
          <th class="px-4 py-2"></th>
        </tr>
      </thead>
      <tbody>
        <%= for user <- @users do %>
          <tr class="border-b border-base-100">
            <td class="px-4 py-2 font-bold text-neutral-content"><%= user.username %></td>
            <td class="px-4 py-2"><%= user.display_name %></td>
            <td class="px-4 py-2 text-[var(--tn-text-muted)]"><%= user.inserted_at %></td>
            <td class="px-4 py-2 text-right">
              <button
                phx-click="delete_user"
                phx-value-id={user.id}
                data-confirm="Delete user #{user.username}?"
                class="text-error text-xs hover:underline"
              >
                delete
              </button>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
</div>
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger_web/live/user_live_test.exs && mix test
```

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/live/user_live.ex lib/wagger_web/live/user_live.html.heex lib/wagger/accounts.ex test/wagger_web/live/user_live_test.exs
git commit -m "Add User Management LiveView with create, list, delete, and API key display"
```

---

### Task 7: End-to-End UI Verification

No new files. Start the dev server and verify all screens in a browser.

- [ ] **Step 1: Start the server**

```bash
mix phx.server
```

Open `http://localhost:4000` in a browser.

- [ ] **Step 2: Verify Dashboard**

- Status summary cards render (should show "never generated" counts)
- Click a status card — app cards appear below
- Click an app name — navigates to app detail

- [ ] **Step 3: Verify App Detail**

- Route display shows SwaggerUI-style endpoint rows
- Method pills are colored correctly
- Path parameters highlighted
- Rate limits shown
- Provider sections visible (collapsed for current, expanded for drifted)
- Import section collapsed at bottom

- [ ] **Step 4: Verify User Management**

- Navigate to Users page
- Create a user — API key displays
- User appears in table
- Delete user works

- [ ] **Step 5: Verify Tokyo Night theme**

- Dark background matches `#1a1b26`
- Nav bar is darker
- Method pill colors match spec (GET green, POST blue, PUT amber, DELETE red)
- Status cards use correct alert colors

- [ ] **Step 6: Fix any issues and commit**

```bash
git add -u && git commit -m "Fix issues found during UI end-to-end verification"
```
