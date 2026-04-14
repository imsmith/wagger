defmodule WaggerWeb.Hooks.NavHook do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :active_nav, :dashboard)}
  end
end
