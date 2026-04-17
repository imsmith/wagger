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

  describe "build_tools_container/1" do
    test "empty tools list produces empty container" do
      container = Builder.build_tools_container([])

      assert %ExYang.Model.Container{name: "tools"} = container
      assert container.body == []
    end

    test "single tool produces a list entry with uses mcp:tool-definition" do
      tools = [
        %{
          name: "search",
          description: "Full-text search",
          input_schema: %{"type" => "object"},
          output_schema: %{"type" => "object"}
        }
      ]

      container = Builder.build_tools_container(tools)

      assert %ExYang.Model.Container{name: "tools"} = container
      assert [list_entry] = container.body
      assert %ExYang.Model.List{name: "tool", key: "name"} = list_entry

      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Leaf{name: "name"} -> true
               _ -> false
             end)

      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Uses{grouping: "mcp:tool-definition"} -> true
               _ -> false
             end)
    end

    test "multiple tools produce multiple list entries" do
      tools = [%{name: "a"}, %{name: "b"}, %{name: "c"}]
      container = Builder.build_tools_container(tools)
      assert length(container.body) == 3
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
