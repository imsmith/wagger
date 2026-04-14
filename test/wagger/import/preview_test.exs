defmodule Wagger.Import.PreviewTest do
  @moduledoc """
  Tests for Wagger.Import.Preview — the preview/confirm flow for route imports.

  Covers conflict detection, HMAC token generation and verification, and
  route insertion. All tests hit the DB via Wagger.DataCase.
  """

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Applications.Route
  alias Wagger.Import.Preview
  alias Wagger.Routes

  setup do
    {:ok, app} = Applications.create_application(%{name: "test-app"})
    {:ok, _route} = Routes.create_route(app, %{path: "/api/users", methods: ["GET"], path_type: "exact"})
    %{app: app}
  end

  describe "build/2" do
    test "returns parsed routes and empty conflicts when no overlap", %{app: app} do
      incoming = [
        %{path: "/api/posts", methods: ["GET"], path_type: "exact", description: nil}
      ]

      preview = Preview.build(app, incoming)

      assert preview.parsed == incoming
      assert preview.conflicts == []
      assert preview.skipped == []
      assert is_binary(preview.preview_token)
    end

    test "detects conflicts with existing routes", %{app: app} do
      incoming = [
        %{path: "/api/users", methods: ["POST"], path_type: "exact", description: "create user"}
      ]

      preview = Preview.build(app, incoming)

      assert length(preview.conflicts) == 1
      conflict = hd(preview.conflicts)
      assert conflict.path == "/api/users"
      assert %Route{} = conflict.existing
      assert conflict.existing.path == "/api/users"
      assert conflict.incoming == hd(incoming)
    end

    test "preview_token is deterministic — same input yields same token", %{app: app} do
      incoming = [
        %{path: "/api/orders", methods: ["GET"], path_type: "exact", description: nil}
      ]

      preview1 = Preview.build(app, incoming)
      preview2 = Preview.build(app, incoming)

      assert preview1.preview_token == preview2.preview_token
    end

    test "propagates skipped list into preview struct", %{app: app} do
      incoming = [%{path: "/api/items", methods: ["GET"], path_type: "exact", description: nil}]
      skipped = ["line 3: ??? bad line"]

      preview = Preview.build(app, incoming, skipped)

      assert preview.skipped == skipped
    end
  end

  describe "verify_token/2" do
    test "returns true for a valid token", %{app: app} do
      incoming = [%{path: "/api/orders", methods: ["GET"], path_type: "exact", description: nil}]
      preview = Preview.build(app, incoming)

      assert Preview.verify_token(incoming, preview.preview_token) == true
    end

    test "returns false for tampered routes", %{app: app} do
      incoming = [%{path: "/api/orders", methods: ["GET"], path_type: "exact", description: nil}]
      preview = Preview.build(app, incoming)

      tampered = [%{path: "/api/EVIL", methods: ["DELETE"], path_type: "exact", description: nil}]

      assert Preview.verify_token(tampered, preview.preview_token) == false
    end
  end

  describe "confirm/2" do
    test "inserts all non-conflicting routes", %{app: app} do
      incoming = [
        %{path: "/api/posts", methods: ["GET"], path_type: "exact", description: "list posts"},
        %{path: "/api/tags", methods: ["GET"], path_type: "exact", description: nil}
      ]

      preview = Preview.build(app, incoming)
      {:ok, inserted} = Preview.confirm(app, preview)

      assert length(inserted) == 2
      paths = Enum.map(inserted, & &1.path)
      assert "/api/posts" in paths
      assert "/api/tags" in paths
    end

    test "skips routes that conflict — does not update existing", %{app: app} do
      existing_before = Routes.list_routes(app)
      existing_route = Enum.find(existing_before, &(&1.path == "/api/users"))

      incoming = [
        %{path: "/api/users", methods: ["POST", "PUT"], path_type: "exact", description: "changed"},
        %{path: "/api/reports", methods: ["GET"], path_type: "exact", description: nil}
      ]

      preview = Preview.build(app, incoming)
      {:ok, inserted} = Preview.confirm(app, preview)

      assert length(inserted) == 1
      assert hd(inserted).path == "/api/reports"

      # existing route is unchanged
      unchanged = Routes.get_route!(app, existing_route.id)
      assert unchanged.methods == existing_route.methods
    end
  end
end
