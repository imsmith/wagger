defmodule Wagger.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :wagger,
    adapter: Ecto.Adapters.SQLite3
end
