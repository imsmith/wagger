defmodule WaggerWeb.WaggerComponents do
  @moduledoc """
  Reusable UI function components for Wagger with a Tokyo Night theme.

  Provides dashboard status cards, HTTP method pills, provider badges,
  and drift diff displays.
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # status_card
  # ---------------------------------------------------------------------------

  @doc """
  Dashboard status summary card.

  Displays a large count with a label. Clicking fires `filter_status` with
  the atom status value. Supports selected (glow) and dimmed (40% opacity)
  states.
  """
  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :status, :atom, required: true
  attr :selected, :boolean, default: false
  attr :dimmed, :boolean, default: false

  def status_card(assigns) do
    ~H"""
    <div
      class={[
        "bg-base-300 rounded-lg p-4 cursor-pointer select-none transition-all",
        "flex flex-col items-center justify-center gap-1 min-w-[120px]",
        border_class(@status),
        @selected && "ring-2 ring-offset-1 ring-offset-base-100 shadow-lg " <> glow_class(@status),
        @dimmed && "opacity-40"
      ]}
      phx-click="filter_status"
      phx-value-status={@status}
    >
      <span class="text-4xl font-bold leading-none"><%= @count %></span>
      <span class="text-xs text-[color:var(--tn-text-muted)] uppercase tracking-wide mt-1">
        <%= @label %>
      </span>
      <%= if @selected do %>
        <span class="text-[10px] font-semibold uppercase tracking-widest mt-1 opacity-70">
          showing
        </span>
      <% end %>
    </div>
    """
  end

  defp border_class(:drifted), do: "border border-warning"
  defp border_class(:current), do: "border border-success"
  defp border_class(:never_generated), do: "border border-neutral"
  defp border_class(_), do: "border border-neutral"

  defp glow_class(:drifted), do: "ring-warning"
  defp glow_class(:current), do: "ring-success"
  defp glow_class(_), do: "ring-neutral"

  # ---------------------------------------------------------------------------
  # method_pill
  # ---------------------------------------------------------------------------

  @doc """
  Colored pill displaying an HTTP method.
  """
  attr :method, :string, required: true

  def method_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center justify-center",
      "min-w-[52px] px-2 py-0.5 rounded",
      "text-xs font-bold text-base-100",
      method_bg_class(@method)
    ]}>
      <%= String.upcase(@method) %>
    </span>
    """
  end

  defp method_bg_class("GET"), do: "bg-[var(--tn-method-get)]"
  defp method_bg_class("POST"), do: "bg-[var(--tn-method-post)]"
  defp method_bg_class("PUT"), do: "bg-[var(--tn-method-put)]"
  defp method_bg_class("PATCH"), do: "bg-[var(--tn-method-put)]"
  defp method_bg_class("DELETE"), do: "bg-[var(--tn-method-delete)]"
  defp method_bg_class(_), do: "bg-[var(--tn-method-other)]"

  # ---------------------------------------------------------------------------
  # provider_badge
  # ---------------------------------------------------------------------------

  @doc """
  Provider status badge.

  Shows the provider name and optional summary text. Visual style reflects
  drift status.
  """
  attr :provider, :string, required: true
  attr :status, :atom, required: true
  attr :summary, :string, default: nil
  attr :dimmed, :boolean, default: false

  def provider_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs",
      provider_badge_class(@status),
      @dimmed && "opacity-40"
    ]}>
      <span class="font-semibold"><%= @provider %></span>
      <%= if @summary do %>
        <span class="opacity-80"><%= @summary %></span>
      <% end %>
    </span>
    """
  end

  defp provider_badge_class(:drifted), do: "bg-warning text-base-100 font-bold"
  defp provider_badge_class(:current), do: "bg-base-300 text-success border border-neutral"
  defp provider_badge_class(:never_generated), do: "bg-base-300 text-[color:var(--tn-text-muted)]"
  defp provider_badge_class(_), do: "bg-base-300 text-[color:var(--tn-text-muted)]"

  # ---------------------------------------------------------------------------
  # drift_diff
  # ---------------------------------------------------------------------------

  @doc """
  Displays route changes (added, removed, modified) in a color-coded list.

  The `changes` map must contain `:added`, `:removed`, and `:modified` keys,
  each holding a list of route maps. Route maps may use atom or string keys.
  """
  attr :changes, :map, required: true

  def drift_diff(assigns) do
    ~H"""
    <div class="font-mono text-xs space-y-0.5">
      <%= for route <- Map.get(@changes, :added, []) do %>
        <div class="text-success">
          <span class="font-bold">+ </span>
          <span><%= route[:path] || route["path"] %></span>
          <%= if methods = route[:methods] || route["methods"] do %>
            <span class="ml-2 opacity-70"><%= format_methods(methods) %></span>
          <% end %>
        </div>
      <% end %>
      <%= for route <- Map.get(@changes, :removed, []) do %>
        <div class="text-error">
          <span class="font-bold">- </span>
          <span><%= route[:path] || route["path"] %></span>
          <%= if methods = route[:methods] || route["methods"] do %>
            <span class="ml-2 opacity-70"><%= format_methods(methods) %></span>
          <% end %>
        </div>
      <% end %>
      <%= for route <- Map.get(@changes, :modified, []) do %>
        <div class="text-warning">
          <span class="font-bold">~ </span>
          <span><%= route[:path] || route["path"] %></span>
          <span class="ml-2 opacity-70">changed</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_methods(methods) when is_list(methods), do: Enum.join(methods, " ")
  defp format_methods(methods) when is_binary(methods), do: methods
  defp format_methods(_), do: ""
end
