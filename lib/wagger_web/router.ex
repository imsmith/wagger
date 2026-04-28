defmodule WaggerWeb.Router do
  @moduledoc false
  use WaggerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WaggerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json", "edn"]
    plug WaggerWeb.Plugs.ApiVersion
    plug WaggerWeb.Plugs.Authenticate
  end

  scope "/", WaggerWeb do
    pipe_through :browser

    live_session :default, on_mount: [{WaggerWeb.Hooks.NavHook, :default}] do
      live "/", DashboardLive, :index
      live "/applications", AppListLive, :index
      live "/applications/:id", AppDetailLive, :show
      live "/users", UserLive, :index
      live "/mcp", McpGeneratorLive, :index
    end

    live_session :hub, on_mount: [{WaggerWeb.Hooks.NavHook, :default}] do
      live "/hub", HubListLive, :index
      live "/hub/:name", HubDetailLive, :show
    end

    get "/mcp/download/:token", McpDownloadController, :show
  end

  scope "/api", WaggerWeb do
    pipe_through :api

    resources "/applications", ApplicationController, except: [:new, :edit] do
      resources "/routes", RouteController, except: [:new, :edit]
    end

    get "/applications/:application_id/export", ExportController, :show

    post "/applications/:application_id/import/bulk", ImportController, :bulk
    post "/applications/:application_id/import/openapi", ImportController, :openapi
    post "/applications/:application_id/import/accesslog", ImportController, :accesslog
    post "/applications/:application_id/import/confirm", ImportController, :confirm

    post "/applications/:application_id/generate/:provider", GenerateController, :create

    get "/applications/:application_id/snapshots", SnapshotController, :index
    get "/applications/:application_id/snapshots/:id", SnapshotController, :show
    get "/applications/:application_id/drift/:provider", DriftController, :show
  end
end
