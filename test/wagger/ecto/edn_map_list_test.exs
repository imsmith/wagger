defmodule Wagger.Ecto.EdnMapListTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wagger.Ecto.EdnMapList

  describe "type/0" do
    test "returns :string" do
      assert EdnMapList.type() == :string
    end
  end

  describe "cast/1" do
    test "accepts list of maps with string keys" do
      input = [%{"name" => "page", "required" => false}]
      assert {:ok, [%{"name" => "page", "required" => false}]} = EdnMapList.cast(input)
    end

    test "accepts list of maps with atom keys, normalizes to string keys" do
      input = [%{name: "page", required: false}]
      assert {:ok, [%{"name" => "page", "required" => false}]} = EdnMapList.cast(input)
    end

    test "accepts empty list" do
      assert {:ok, []} = EdnMapList.cast([])
    end

    test "accepts list of maps with integer values" do
      input = [%{"page" => 1, "limit" => 100}]
      assert {:ok, [%{"page" => 1, "limit" => 100}]} = EdnMapList.cast(input)
    end

    test "rejects non-list" do
      assert :error = EdnMapList.cast("not a list")
    end

    test "rejects nil" do
      assert :error = EdnMapList.cast(nil)
    end

    test "rejects list containing non-maps" do
      assert :error = EdnMapList.cast(["not a map"])
    end
  end

  describe "dump/1" do
    test "serializes list of maps to EDN" do
      input = [%{"name" => "page", "required" => false}]
      {:ok, result} = EdnMapList.dump(input)
      assert is_binary(result)
      assert String.starts_with?(result, "[")
      assert String.ends_with?(result, "]")
      assert String.contains?(result, ":name")
      assert String.contains?(result, "\"page\"")
      assert String.contains?(result, ":required")
      assert String.contains?(result, "false")
    end

    test "serializes empty list" do
      assert {:ok, "[]"} = EdnMapList.dump([])
    end

    test "serializes map with boolean true" do
      {:ok, result} = EdnMapList.dump([%{"active" => true}])
      assert String.contains?(result, "true")
    end

    test "serializes map with integer value" do
      {:ok, result} = EdnMapList.dump([%{"count" => 42}])
      assert String.contains?(result, "42")
    end

    test "serializes map with nil value" do
      {:ok, result} = EdnMapList.dump([%{"val" => nil}])
      assert String.contains?(result, "nil")
    end
  end

  describe "load/1" do
    test "deserializes EDN to list of maps with string keys" do
      {:ok, result} = EdnMapList.load("[{:name \"page\" :required false}]")
      assert [%{"name" => "page", "required" => false}] = result
    end

    test "loads nil as empty list" do
      assert {:ok, []} = EdnMapList.load(nil)
    end

    test "deserializes empty EDN vector" do
      assert {:ok, []} = EdnMapList.load("[]")
    end

    test "deserializes boolean true" do
      {:ok, result} = EdnMapList.load("[{:active true}]")
      assert [%{"active" => true}] = result
    end

    test "deserializes integer value" do
      {:ok, result} = EdnMapList.load("[{:count 42}]")
      assert [%{"count" => 42}] = result
    end

    test "deserializes nil value" do
      {:ok, result} = EdnMapList.load("[{:val nil}]")
      assert [%{"val" => nil}] = result
    end

    test "deserializes string value" do
      {:ok, result} = EdnMapList.load("[{:name \"foo\"}]")
      assert [%{"name" => "foo"}] = result
    end

    test "round-trips through dump and load" do
      original = [
        %{"name" => "page", "required" => false},
        %{"name" => "limit", "required" => true}
      ]

      {:ok, dumped} = EdnMapList.dump(original)
      {:ok, loaded} = EdnMapList.load(dumped)
      assert length(loaded) == 2
      # Keys and values should survive the round-trip
      page_map = Enum.find(loaded, fn m -> m["name"] == "page" end)
      assert page_map["required"] == false
      limit_map = Enum.find(loaded, fn m -> m["name"] == "limit" end)
      assert limit_map["required"] == true
    end
  end
end
