defmodule Wagger.SnapshotsTest do
  @moduledoc """
  Tests for the Wagger.Snapshots context module.

  Covers snapshot creation, listing with filters, scoped retrieval, and latest-snapshot lookup.
  """

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Snapshots
  alias Wagger.Snapshots.Snapshot

  @app_attrs %{"name" => "test-app"}

  @valid_snapshot %{
    "provider" => "nginx",
    "config_params" => "{:timeout 30}",
    "route_snapshot" => "[{:path \"/api\"}]",
    "output" => "server { location /api {} }",
    "checksum" => "abc123"
  }

  defp create_app! do
    {:ok, app} = Applications.create_application(@app_attrs)
    app
  end

  defp snapshot_for(app, overrides \\ %{}) do
    Map.merge(@valid_snapshot, overrides)
    |> Map.put("application_id", app.id)
  end

  describe "create_snapshot/1" do
    test "creates with valid attrs" do
      app = create_app!()
      attrs = snapshot_for(app)

      assert {:ok, %Snapshot{} = snap} = Snapshots.create_snapshot(attrs)
      assert snap.provider == "nginx"
      assert snap.checksum == "abc123"
      assert snap.application_id == app.id
    end

    test "requires application_id" do
      assert {:error, changeset} = Snapshots.create_snapshot(@valid_snapshot)
      assert %{application_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires provider" do
      app = create_app!()
      attrs = snapshot_for(app, %{"provider" => nil})

      assert {:error, changeset} = Snapshots.create_snapshot(attrs)
      assert %{provider: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires route_snapshot" do
      app = create_app!()
      attrs = snapshot_for(app, %{"route_snapshot" => nil})

      assert {:error, changeset} = Snapshots.create_snapshot(attrs)
      assert %{route_snapshot: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires output" do
      app = create_app!()
      attrs = snapshot_for(app, %{"output" => nil})

      assert {:error, changeset} = Snapshots.create_snapshot(attrs)
      assert %{output: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires checksum" do
      app = create_app!()
      attrs = snapshot_for(app, %{"checksum" => nil})

      assert {:error, changeset} = Snapshots.create_snapshot(attrs)
      assert %{checksum: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_snapshots/2" do
    test "returns all snapshots for the app" do
      app = create_app!()
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app, %{"provider" => "nginx"}))
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app, %{"provider" => "aws"}))

      snaps = Snapshots.list_snapshots(app)
      assert length(snaps) == 2
    end

    test "does not return snapshots from other apps" do
      app1 = create_app!()
      {:ok, app2} = Applications.create_application(%{"name" => "other-app"})

      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app1))
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app2))

      snaps = Snapshots.list_snapshots(app1)
      assert length(snaps) == 1
      assert hd(snaps).application_id == app1.id
    end

    test "filters by provider" do
      app = create_app!()
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app, %{"provider" => "nginx"}))
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app, %{"provider" => "aws"}))

      snaps = Snapshots.list_snapshots(app, %{"provider" => "nginx"})
      assert length(snaps) == 1
      assert hd(snaps).provider == "nginx"
    end

    test "orders by id descending" do
      app = create_app!()
      {:ok, first} = Snapshots.create_snapshot(snapshot_for(app, %{"checksum" => "first"}))
      {:ok, second} = Snapshots.create_snapshot(snapshot_for(app, %{"checksum" => "second"}))

      snaps = Snapshots.list_snapshots(app)
      assert length(snaps) == 2
      assert hd(snaps).id == second.id
      assert List.last(snaps).id == first.id
    end
  end

  describe "get_snapshot!/2" do
    test "returns the snapshot scoped to the app" do
      app = create_app!()
      {:ok, snap} = Snapshots.create_snapshot(snapshot_for(app))

      fetched = Snapshots.get_snapshot!(app, snap.id)
      assert fetched.id == snap.id
    end

    test "raises when snapshot belongs to a different app" do
      app1 = create_app!()
      {:ok, app2} = Applications.create_application(%{"name" => "other-app"})
      {:ok, snap} = Snapshots.create_snapshot(snapshot_for(app2))

      assert_raise Ecto.NoResultsError, fn ->
        Snapshots.get_snapshot!(app1, snap.id)
      end
    end

    test "raises when snapshot does not exist" do
      app = create_app!()

      assert_raise Ecto.NoResultsError, fn ->
        Snapshots.get_snapshot!(app, 0)
      end
    end
  end

  describe "latest_snapshot/2" do
    test "returns the most recent snapshot for app+provider" do
      app = create_app!()
      {:ok, _older} = Snapshots.create_snapshot(snapshot_for(app, %{"checksum" => "old"}))
      {:ok, newer} = Snapshots.create_snapshot(snapshot_for(app, %{"checksum" => "new"}))

      result = Snapshots.latest_snapshot(app, "nginx")
      assert result.id == newer.id
      assert result.checksum == "new"
    end

    test "returns nil when no snapshots exist for app+provider" do
      app = create_app!()

      assert nil == Snapshots.latest_snapshot(app, "nginx")
    end

    test "does not return snapshots from other providers" do
      app = create_app!()
      {:ok, _} = Snapshots.create_snapshot(snapshot_for(app, %{"provider" => "aws"}))

      assert nil == Snapshots.latest_snapshot(app, "nginx")
    end
  end
end
