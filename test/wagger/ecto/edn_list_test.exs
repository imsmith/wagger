defmodule Wagger.Ecto.EdnListTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wagger.Ecto.EdnList

  describe "type/0" do
    test "returns :string" do
      assert EdnList.type() == :string
    end
  end

  describe "cast/1" do
    test "accepts list of strings" do
      assert {:ok, ["GET", "POST"]} = EdnList.cast(["GET", "POST"])
    end

    test "accepts list of atoms, normalizes to strings" do
      assert {:ok, ["GET", "POST"]} = EdnList.cast([:GET, :POST])
    end

    test "accepts empty list" do
      assert {:ok, []} = EdnList.cast([])
    end

    test "accepts mixed atom and string list" do
      assert {:ok, ["GET", "POST"]} = EdnList.cast([:GET, "POST"])
    end

    test "rejects non-list" do
      assert :error = EdnList.cast("GET")
    end

    test "rejects nil" do
      assert :error = EdnList.cast(nil)
    end

    test "rejects map" do
      assert :error = EdnList.cast(%{"a" => "b"})
    end
  end

  describe "dump/1" do
    test "serializes list of strings to EDN keyword vector" do
      assert {:ok, "[:GET :POST]"} = EdnList.dump(["GET", "POST"])
    end

    test "serializes empty list to empty EDN vector" do
      assert {:ok, "[]"} = EdnList.dump([])
    end

    test "serializes single-element list" do
      assert {:ok, "[:DELETE]"} = EdnList.dump(["DELETE"])
    end
  end

  describe "load/1" do
    test "deserializes EDN keyword vector to list of strings" do
      assert {:ok, ["GET", "POST"]} = EdnList.load("[:GET :POST]")
    end

    test "deserializes empty EDN vector to empty list" do
      assert {:ok, []} = EdnList.load("[]")
    end

    test "loads nil as empty list" do
      assert {:ok, []} = EdnList.load(nil)
    end

    test "deserializes single-element EDN vector" do
      assert {:ok, ["DELETE"]} = EdnList.load("[:DELETE]")
    end

    test "round-trips through dump and load" do
      original = ["GET", "POST", "DELETE"]
      {:ok, dumped} = EdnList.dump(original)
      assert {:ok, ^original} = EdnList.load(dumped)
    end
  end
end
