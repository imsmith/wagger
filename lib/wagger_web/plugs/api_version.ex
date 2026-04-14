defmodule WaggerWeb.Plugs.ApiVersion do
  @moduledoc """
  Plug that parses API version from the Accept header.

  Extracts the version number from `Accept: application/vnd.wagger+json; version=N`
  headers and assigns it to `conn.assigns[:api_version]`. Defaults to version 1
  if no version is specified or the header is missing.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    version =
      conn
      |> get_req_header("accept")
      |> List.first("")
      |> extract_version()

    assign(conn, :api_version, version)
  end

  defp extract_version(accept) do
    case Regex.run(~r/application\/vnd\.wagger\+json;\s*version=(\d+)/, accept) do
      [_, version] -> String.to_integer(version)
      _ -> 1
    end
  end
end
