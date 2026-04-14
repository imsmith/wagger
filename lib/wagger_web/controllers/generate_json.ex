defmodule WaggerWeb.GenerateJSON do
  @moduledoc false

  def created(%{output: output, provider: provider, snapshot_id: snapshot_id}) do
    %{output: output, provider: provider, snapshot_id: snapshot_id}
  end
end
