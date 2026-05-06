defmodule WaggerWeb.OauthCredentialsLive do
  @moduledoc false
  use WaggerWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H"<div>OAuth credentials (stub)</div>"
end
