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

    get "/", PageController, :home
  end

  scope "/api", WaggerWeb do
    pipe_through :api
    resources "/applications", ApplicationController, except: [:new, :edit] do
      resources "/routes", RouteController, except: [:new, :edit]
    end

    get "/applications/:application_id/export", ExportController, :show
  end
end
