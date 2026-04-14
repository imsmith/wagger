defmodule WaggerWeb.SnapshotJSON do
  @moduledoc false

  def index(%{snapshots: snapshots}) do
    %{data: Enum.map(snapshots, &summary/1)}
  end

  def show(%{snapshot: snapshot}) do
    %{data: detail(snapshot)}
  end

  defp summary(snapshot) do
    %{
      id: snapshot.id,
      provider: snapshot.provider,
      checksum: snapshot.checksum,
      inserted_at: snapshot.inserted_at
    }
  end

  defp detail(snapshot) do
    snapshot
    |> summary()
    |> Map.merge(%{
      config_params: snapshot.config_params,
      output: snapshot.output
    })
  end
end
