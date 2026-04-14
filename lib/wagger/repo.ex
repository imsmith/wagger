defmodule Wagger.Repo do
  use Ecto.Repo,
    otp_app: :wagger,
    adapter: Ecto.Adapters.SQLite3
end
