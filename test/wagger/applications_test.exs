defmodule Wagger.ApplicationsTest do
  @moduledoc """
  Tests for the Wagger.Applications context module.

  Covers CRUD operations and tag-based filtering over the applications table.
  """

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Applications.Application

  @valid_attrs %{
    "name" => "my-app",
    "description" => "A test application",
    "tags" => ["api", "public"]
  }
  @update_attrs %{
    "name" => "my-app-v2",
    "description" => "Updated description",
    "tags" => ["internal"]
  }
  @invalid_attrs %{"name" => nil}

  describe "create_application/1" do
    test "creates with valid attrs" do
      assert {:ok, %Application{} = app} = Applications.create_application(@valid_attrs)
      assert app.name == "my-app"
      assert app.description == "A test application"
      assert app.tags == ["api", "public"]
    end

    test "rejects duplicate name" do
      assert {:ok, _} = Applications.create_application(@valid_attrs)
      assert {:error, changeset} = Applications.create_application(@valid_attrs)
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires name" do
      assert {:error, changeset} = Applications.create_application(@invalid_attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects name that is not a lowercase slug" do
      assert {:error, changeset} = Applications.create_application(%{"name" => "My App"})
      assert %{name: [_msg]} = errors_on(changeset)
    end

    test "rejects name with uppercase letters" do
      assert {:error, changeset} = Applications.create_application(%{"name" => "MyApp"})
      assert %{name: [_msg]} = errors_on(changeset)
    end
  end

  describe "list_applications/1" do
    test "returns all applications when no filter" do
      {:ok, _} = Applications.create_application(%{"name" => "app-one", "tags" => ["api"]})
      {:ok, _} = Applications.create_application(%{"name" => "app-two", "tags" => ["internal"]})

      apps = Applications.list_applications()
      assert length(apps) == 2
    end

    test "filters by tag" do
      {:ok, _} =
        Applications.create_application(%{"name" => "app-api", "tags" => ["api", "public"]})

      {:ok, _} =
        Applications.create_application(%{"name" => "app-private", "tags" => ["internal"]})

      result = Applications.list_applications(%{"tag" => "api"})
      assert length(result) == 1
      assert hd(result).name == "app-api"
    end

    test "returns empty list when no apps match tag filter" do
      {:ok, _} = Applications.create_application(%{"name" => "app-one", "tags" => ["internal"]})

      result = Applications.list_applications(%{"tag" => "nonexistent"})
      assert result == []
    end

    test "returns all when filter has no tag key" do
      {:ok, _} = Applications.create_application(%{"name" => "app-one"})
      {:ok, _} = Applications.create_application(%{"name" => "app-two"})

      result = Applications.list_applications(%{})
      assert length(result) == 2
    end
  end

  describe "get_application!/1" do
    test "returns the application by id" do
      {:ok, created} = Applications.create_application(@valid_attrs)
      fetched = Applications.get_application!(created.id)
      assert fetched.id == created.id
      assert fetched.name == created.name
    end

    test "raises on missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application!(0)
      end
    end
  end

  describe "update_application/2" do
    test "updates with valid attrs" do
      {:ok, app} = Applications.create_application(@valid_attrs)
      assert {:ok, updated} = Applications.update_application(app, @update_attrs)
      assert updated.name == "my-app-v2"
      assert updated.description == "Updated description"
      assert updated.tags == ["internal"]
    end

    test "returns error changeset for invalid attrs" do
      {:ok, app} = Applications.create_application(@valid_attrs)
      assert {:error, changeset} = Applications.update_application(app, @invalid_attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "delete_application/1" do
    test "removes the application" do
      {:ok, app} = Applications.create_application(@valid_attrs)
      assert {:ok, %Application{}} = Applications.delete_application(app)

      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application!(app.id)
      end
    end
  end
end
