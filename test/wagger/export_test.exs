defmodule Wagger.ExportTest do
  @moduledoc false

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Export
  alias Wagger.Routes

  describe "to_edn/1" do
    setup do
      {:ok, app} =
        Applications.create_application(%{"name" => "export-test-app", "tags" => ["api"]})

      {:ok, app: app}
    end

    test "returns {:ok, edn_string}", %{app: app} do
      assert {:ok, edn} = Export.to_edn(app)
      assert is_binary(edn)
    end

    test "contains version 1.0", %{app: app} do
      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ~s(:version "1.0")
    end

    test "contains exported timestamp", %{app: app} do
      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":exported"
    end

    test "exports empty routes as :routes []", %{app: app} do
      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":routes []"
    end

    test "contains :path for created route", %{app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "methods" => ["GET", "POST"],
          "path_type" => "exact",
          "description" => "User endpoint",
          "query_params" => [%{"name" => "page", "required" => false}],
          "headers" => [%{"name" => "Authorization", "required" => true}],
          "rate_limit" => 100,
          "tags" => ["api"]
        })

      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ~s(:path "/api/users")
    end

    test "contains :methods [:GET :POST]", %{app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "methods" => ["GET", "POST"],
          "path_type" => "exact"
        })

      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":methods [:GET :POST]"
    end

    test "contains :path-type :exact (hyphenated)", %{app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "path_type" => "exact"
        })

      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":path-type :exact"
    end

    test "contains :rate-limit integer (hyphenated)", %{app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "path_type" => "exact",
          "rate_limit" => 100
        })

      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":rate-limit 100"
    end

    test "exports nil rate-limit as nil", %{app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "path_type" => "exact"
        })

      {:ok, edn} = Export.to_edn(app)
      assert edn =~ ":rate-limit nil"
    end
  end
end
