defmodule Wagger.Generator.ValidatorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wagger.Generator.Validator

  @yang_source """
  module test-validator {
    namespace "urn:test:validator";
    prefix tv;

    container config {
      leaf name {
        type string;
        mandatory true;
      }
      leaf port {
        type uint16;
      }
      leaf mode {
        type enumeration {
          enum "block";
          enum "allow";
        }
      }
      leaf-list tags {
        type string;
      }
      container nested {
        leaf value {
          type string;
        }
      }
      list rules {
        key "id";
        leaf id {
          type uint32;
          mandatory true;
        }
        leaf pattern {
          type string;
        }
      }
    }
  }
  """

  setup_all do
    {:ok, parsed} = ExYang.parse(@yang_source)
    {:ok, resolved} = ExYang.resolve(parsed, %{})
    %{schema: resolved}
  end

  # 1. Accept valid complete instance
  test "accepts valid complete instance", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "main",
        "port" => 8080,
        "mode" => "block",
        "tags" => ["web", "api"],
        "nested" => %{"value" => "hello"},
        "rules" => [
          %{"id" => 1, "pattern" => "*.log"},
          %{"id" => 2, "pattern" => "*.tmp"}
        ]
      }
    }

    assert :ok = Validator.validate(data, schema)
  end

  # 2. Accept minimal valid instance (only mandatory fields)
  test "accepts minimal valid instance with only mandatory fields", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "minimal"
      }
    }

    assert :ok = Validator.validate(data, schema)
  end

  # 3. Reject missing mandatory leaf
  test "rejects missing mandatory leaf", %{schema: schema} do
    data = %{
      "config" => %{
        "port" => 9000
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &String.contains?(&1, "mandatory leaf missing"))
    assert Enum.any?(errors, &String.contains?(&1, "name"))
  end

  # 4. Reject wrong type for integer leaf (string where uint16 expected)
  test "rejects string value where uint16 expected", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "port" => "not-a-number"
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "port") && String.contains?(&1, "integer")))
  end

  # 5. Reject wrong type for string leaf (integer where string expected)
  test "rejects integer value where string expected", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => 42
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "name") && String.contains?(&1, "string")))
  end

  # 6. Reject invalid enum value
  test "rejects invalid enum value", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "mode" => "deny"
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "mode") && String.contains?(&1, "invalid enum")))
  end

  # 7. Reject list entry missing key leaf
  test "rejects list entry missing key leaf", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "rules" => [
          %{"pattern" => "*.log"}
        ]
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "id") && String.contains?(&1, "key")))
  end

  # 8. Reject duplicate list keys
  test "rejects duplicate list keys", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "rules" => [
          %{"id" => 1, "pattern" => "*.log"},
          %{"id" => 1, "pattern" => "*.txt"}
        ]
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &String.contains?(&1, "duplicate"))
  end

  # 9. Reject non-list for leaf-list
  test "rejects non-list value for leaf-list", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "tags" => "not-a-list"
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "tags") && String.contains?(&1, "list")))
  end

  # 10. Reject wrong item type in leaf-list
  test "rejects wrong item type in leaf-list", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "tags" => ["valid", 42, "also-valid"]
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "tags") && String.contains?(&1, "string")))
  end

  # 11. Reject unknown keys in container
  test "rejects unknown keys in container", %{schema: schema} do
    data = %{
      "config" => %{
        "name" => "test",
        "unknown_field" => "value"
      }
    }

    assert {:error, errors} = Validator.validate(data, schema)
    assert Enum.any?(errors, &(String.contains?(&1, "unknown_field") && String.contains?(&1, "unknown")))
  end
end
