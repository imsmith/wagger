defmodule Wagger.Import.Preview do
  @moduledoc """
  Handles the preview/confirm flow for the import pipeline.

  Compares incoming parsed routes against existing DB routes, detects
  conflicts, issues an HMAC token binding the routes to the preview, and
  inserts only the non-conflicting routes when the user confirms.

  The HMAC token allows the controller to round-trip the route list through
  a form submission and confirm that it has not been tampered with between
  the preview and confirm steps.
  """

  alias Wagger.Applications.Application
  alias Wagger.Routes

  @hmac_secret Elixir.Application.compile_env(
                 :wagger,
                 :import_hmac_secret,
                 "wagger-import-default-secret"
               )

  @enforce_keys [:parsed, :conflicts, :skipped, :preview_token]
  defstruct [:parsed, :conflicts, :skipped, :preview_token]

  @type conflict :: %{path: String.t(), existing: struct(), incoming: map()}

  @type t :: %__MODULE__{
          parsed: [map()],
          conflicts: [conflict()],
          skipped: [String.t()],
          preview_token: String.t()
        }

  @doc """
  Builds a preview by comparing `incoming_routes` against routes already
  stored for `app`.

  Each incoming route whose path already exists in the app is recorded in
  `conflicts` with both the existing DB struct and the incoming map. All
  incoming routes (including conflicting ones) are included in `parsed`.

  An HMAC token is computed over all incoming routes and stored in
  `preview_token`. Pass `skipped` from the parser's second tuple element to
  carry unparseable lines through to the preview struct.

  Returns a `%Preview{}` struct.
  """
  @spec build(Application.t(), [map()], [String.t()]) :: t()
  def build(%Application{} = app, incoming_routes, skipped \\ []) do
    existing = Routes.list_routes(app)
    existing_by_path = Map.new(existing, &{&1.path, &1})

    conflicts =
      incoming_routes
      |> Enum.filter(&Map.has_key?(existing_by_path, &1.path))
      |> Enum.map(fn incoming ->
        %{path: incoming.path, existing: existing_by_path[incoming.path], incoming: incoming}
      end)

    token = compute_hmac(incoming_routes)

    %__MODULE__{
      parsed: incoming_routes,
      conflicts: conflicts,
      skipped: skipped,
      preview_token: token
    }
  end

  @doc """
  Recomputes the HMAC of `routes` and compares it against `token`.

  Returns `true` if the token is valid, `false` otherwise.
  """
  @spec verify_token([map()], String.t()) :: boolean()
  def verify_token(routes, token) when is_list(routes) and is_binary(token) do
    expected = compute_hmac(routes)
    Plug.Crypto.secure_compare(expected, token)
  end

  @doc """
  Inserts all non-conflicting routes from `preview` into the database for `app`.

  Routes whose path appears in the conflict list are skipped entirely —
  existing records are not updated. Returns `{:ok, [%Route{}]}`.
  """
  @spec confirm(Application.t(), t()) :: {:ok, [struct()]}
  def confirm(%Application{} = app, %__MODULE__{} = preview) do
    conflict_paths = MapSet.new(preview.conflicts, & &1.path)

    results =
      preview.parsed
      |> Enum.reject(&MapSet.member?(conflict_paths, &1.path))
      |> Enum.map(fn attrs ->
        {:ok, route} = Routes.create_route(app, attrs)
        route
      end)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp compute_hmac(routes) do
    data = :erlang.term_to_binary(routes)
    :crypto.mac(:hmac, :sha256, @hmac_secret, data) |> Base.encode16(case: :lower)
  end
end
