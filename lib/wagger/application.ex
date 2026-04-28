defmodule Wagger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WaggerWeb.Telemetry,
      Wagger.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:wagger, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:wagger, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Wagger.PubSub},
      # Start a worker by calling: Wagger.Worker.start_link(arg)
      # {Wagger.Worker, arg},
      # Start to serve requests, typically the last entry
      WaggerWeb.Endpoint
    ] ++ busybody_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Wagger.Supervisor]
    result = Supervisor.start_link(children, opts)

    Code.ensure_loaded!(Wagger.Errors)
    Comn.Errors.Registry.register_module(Wagger.Errors)

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WaggerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp busybody_children do
    if Code.ensure_loaded?(Busybody.Client) do
      [{Busybody.Client, name: "Wagger", endpoint: WaggerWeb.Endpoint}]
    else
      []
    end
  end

end
