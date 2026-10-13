defmodule Wagger.Generator.RegistryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Wagger.Generator

  test "every provider is in exactly one UI bucket" do
    bucketed = Generator.buckets() |> Enum.flat_map(fn {_label, names} -> names end)
    assert Enum.sort(bucketed) == Generator.provider_names()
  end

  test "every provider has config fields that at least name a prefix" do
    for name <- Generator.provider_names() do
      assert {"prefix", _, :text} = List.first(Generator.config_fields(name)), name
    end
  end

  test "every provider spec resolves to a loaded Generator implementation" do
    for {_name, spec} <- Generator.providers(),
        mod <-
          List.wrap(spec)
          |> Enum.map(fn
            {_, m, _} -> m
            m -> m
          end) do
      assert Code.ensure_loaded?(mod)
      assert function_exported?(mod, :yang_module, 0)
    end
  end
end
