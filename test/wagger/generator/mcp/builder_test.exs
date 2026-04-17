defmodule Wagger.Generator.Mcp.BuilderTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wagger.Generator.Mcp.Builder

  describe "validate/1" do
    test "accepts minimal valid capability map" do
      caps = %{app_name: "my-app", tools: [], resources: [], prompts: []}
      assert :ok = Builder.validate(caps)
    end

    test "rejects missing app_name" do
      assert {:error, {:missing, "app_name"}} =
               Builder.validate(%{tools: [], resources: [], prompts: []})
    end

    test "rejects invalid app_name (not a valid YANG identifier)" do
      assert {:error, {:invalid_identifier, "app_name", "9bad"}} =
               Builder.validate(%{app_name: "9bad", tools: [], resources: [], prompts: []})

      assert {:error, {:invalid_identifier, "app_name", "bad space"}} =
               Builder.validate(%{app_name: "bad space", tools: [], resources: [], prompts: []})
    end

    test "rejects tool without name" do
      caps = %{app_name: "my-app", tools: [%{description: "x"}], resources: [], prompts: []}
      assert {:error, {:missing, "tools[0].name"}} = Builder.validate(caps)
    end

    test "rejects duplicate tool names" do
      caps = %{
        app_name: "my-app",
        tools: [%{name: "search"}, %{name: "search"}],
        resources: [],
        prompts: []
      }
      assert {:error, {:duplicate, "tools", "search"}} = Builder.validate(caps)
    end

    test "rejects resource without uri_template" do
      caps = %{
        app_name: "my-app",
        tools: [],
        resources: [%{name: "r"}],
        prompts: []
      }
      assert {:error, {:missing, "resources[0].uri_template"}} = Builder.validate(caps)
    end

    test "rejects prompt without name" do
      caps = %{
        app_name: "my-app",
        tools: [],
        resources: [],
        prompts: [%{description: "x"}]
      }
      assert {:error, {:missing, "prompts[0].name"}} = Builder.validate(caps)
    end

    test "defaults missing primitive lists to empty" do
      assert :ok = Builder.validate(%{app_name: "my-app"})
    end
  end

  describe "derive_identity/1" do
    test "derives module_name, namespace, and prefix from app_name" do
      assert %{
               module_name: "my-app-mcp",
               namespace: "urn:wagger:my-app:mcp",
               prefix: "my-app"
             } = Builder.derive_identity(%{app_name: "my-app"})
    end

    test "handles single-word app names" do
      assert %{
               module_name: "acme-mcp",
               namespace: "urn:wagger:acme:mcp",
               prefix: "acme"
             } = Builder.derive_identity(%{app_name: "acme"})
    end
  end
end
