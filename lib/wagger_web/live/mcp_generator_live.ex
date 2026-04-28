defmodule WaggerWeb.McpGeneratorLive do
  @moduledoc """
  Standalone page for generating an MCP module from annotated YANG.

  Stateless one-shot: paste YANG → submit → derivation report,
  generated YANG source, and a token-signed download link rendered inline.
  """

  use WaggerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, result: nil, source: "", page_title: "MCP Generator", active_nav: nil)}
  end

  @impl true
  def handle_event("generate", %{"yang_source" => source}, socket) do
    {app_name, app_name_fallback?} =
      case derive_app_name(source) do
        {:ok, name} -> {name, false}
        :fallback -> {"service", true}
      end

    case Wagger.Generator.Mcp.generate_from_yang(source, app_name) do
      {:ok, yang_text, report} ->
        filename = "#{app_name}-mcp.yang"

        token =
          Phoenix.Token.sign(WaggerWeb.Endpoint, "mcp-download", %{
            yang_text: yang_text,
            filename: filename
          })

        {:noreply,
         assign(socket,
           result:
             {:ok,
              %{
                yang_text: yang_text,
                report: report,
                filename: filename,
                token: token,
                app_name_fallback?: app_name_fallback?
              }},
           source: source
         )}

      {:error, err} ->
        {:noreply, assign(socket, result: {:error, err}, source: source)}
    end
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  attr :result, :map, required: true

  def ok_result(assigns) do
    ~H"""
    <section class="border rounded p-4 space-y-4">
      <div :if={@result.app_name_fallback?} class="border-l-4 border-yellow-400 bg-yellow-50 p-3">
        <p class="text-sm text-yellow-800">
          Could not detect a <code>module &lt;name&gt;</code> declaration; defaulting to
          <code>service-mcp.yang</code>. Check your YANG source.
        </p>
      </div>
      <h2 class="text-lg font-semibold">Derivation report</h2>
      <p class="text-sm">
        <%= @result.report.tools_count %> tool<%= if @result.report.tools_count == 1, do: "", else: "s" %>,
        <%= @result.report.resources_count %> resource<%= if @result.report.resources_count == 1, do: "", else: "s" %>,
        <%= @result.report.prompts_count %> prompt<%= if @result.report.prompts_count == 1, do: "", else: "s" %>.
      </p>

      <div :if={@result.report.warnings != []} class="border-l-4 border-yellow-400 bg-yellow-50 p-3">
        <h3 class="font-semibold text-yellow-800">Warnings</h3>
        <ul class="text-sm">
          <li :for={w <- @result.report.warnings}><code><%= w.node %></code>: <%= w.message %></li>
        </ul>
      </div>

      <div :if={@result.report.excluded != []} class="text-sm">
        <h3 class="font-semibold">Excluded</h3>
        <ul>
          <li :for={n <- @result.report.excluded}><code><%= n %></code></li>
        </ul>
      </div>

      <details>
        <summary class="cursor-pointer font-semibold">Tools (<%= @result.report.tools_count %>)</summary>
        <table class="text-sm w-full">
          <thead><tr><th>name</th><th>description</th><th>flags</th></tr></thead>
          <tbody>
            <tr :for={t <- @result.report.tools}>
              <td><code><%= t.name %></code></td>
              <td><%= t.description %></td>
              <td>
                <%= if t.dangerous, do: "dangerous " %>
                <%= if t.read_only, do: "read-only" %>
              </td>
            </tr>
          </tbody>
        </table>
      </details>

      <details>
        <summary class="cursor-pointer font-semibold">Resources (<%= @result.report.resources_count %>)</summary>
        <ul class="text-sm">
          <li :for={r <- @result.report.resources}>
            <code><%= r.uri_template %></code> — <%= r.mime_type %>
          </li>
        </ul>
      </details>

      <details>
        <summary class="cursor-pointer font-semibold">Prompts (<%= @result.report.prompts_count %>)</summary>
        <ul class="text-sm">
          <li :for={p <- @result.report.prompts}><code><%= p.name %></code> — <%= p.description %></li>
        </ul>
      </details>
    </section>

    <section class="border rounded p-4 space-y-2">
      <div class="flex justify-between items-center">
        <h2 class="text-lg font-semibold">Generated YANG</h2>
        <a href={~p"/mcp/download/#{@result.token}"} class="px-3 py-1 bg-green-600 text-white rounded text-sm">
          Download <%= @result.filename %>
        </a>
      </div>
      <pre class="bg-gray-50 p-3 text-xs overflow-x-auto"><code><%= @result.yang_text %></code></pre>
    </section>
    """
  end

  attr :err, :map, required: true

  def error_result(assigns) do
    ~H"""
    <section class="border-l-4 border-red-500 bg-red-50 p-4">
      <h2 class="font-bold text-red-800">Generation failed</h2>
      <p class="text-sm"><code><%= @err.code %></code></p>
      <p class="text-sm"><%= @err.message %></p>
    </section>
    """
  end

  defp derive_app_name(source) do
    case Regex.run(~r/^\s*module\s+([a-zA-Z_][a-zA-Z0-9_\-]*)/m, source) do
      [_, name] -> {:ok, String.replace_suffix(name, "-mcp", "")}
      _ -> :fallback
    end
  end
end
