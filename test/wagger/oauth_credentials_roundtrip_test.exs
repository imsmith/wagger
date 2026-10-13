defmodule Wagger.OauthCredentialsRoundtripTest do
  @moduledoc """
  Integration test for the encrypt-at-rest contract: a credential persisted
  via Wagger.Secrets must come back identical after load_into_app_env/0
  publishes it into the Application env.
  """

  use Wagger.DataCase

  alias Wagger.OauthCredentials

  setup do
    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    end)

    :ok
  end

  test "persisted secret round-trips through Wagger.Secrets and into app env" do
    plain_secret = "rotation-token-#{System.unique_integer()}"
    {:ok, _} = OauthCredentials.upsert("google", "round-trip-id", plain_secret)

    Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    :ok = OauthCredentials.load_into_app_env()

    cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    assert cfg[:client_id] == "round-trip-id"
    assert cfg[:client_secret] == plain_secret
  end
end
