# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :wagger,
  ecto_repos: [Wagger.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :wagger, WaggerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WaggerWeb.ErrorHTML, json: WaggerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Wagger.PubSub,
  live_view: [signing_salt: "i+8OvG5R"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wagger: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  wagger: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Register custom MIME types
config :mime, :types, %{
  "application/edn" => ["edn"]
}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Use Tidewave for live reloading in development
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
