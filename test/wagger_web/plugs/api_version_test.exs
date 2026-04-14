defmodule WaggerWeb.Plugs.ApiVersionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias WaggerWeb.Plugs.ApiVersion

  test "extracts version from vnd.wagger+json accept header" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/vnd.wagger+json; version=1")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "defaults to version 1 with plain application/json" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/json")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "defaults to version 1 with no accept header" do
    conn =
      conn(:get, "/api/applications")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 1
  end

  test "extracts version 2" do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("accept", "application/vnd.wagger+json; version=2")
      |> ApiVersion.call(ApiVersion.init([]))

    assert conn.assigns[:api_version] == 2
  end
end
