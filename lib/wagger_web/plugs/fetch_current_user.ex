defmodule WaggerWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the current user (if any) from the session into `conn.assigns.current_user`.
  Never halts; assigns nil for missing or stale sessions.
  """

  import Plug.Conn

  alias Wagger.Repo
  alias Wagger.Accounts.User

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && Repo.get(User, user_id)
    assign(conn, :current_user, user)
  end
end
