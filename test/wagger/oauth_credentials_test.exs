defmodule Wagger.OauthCredentialsTest do
  @moduledoc """
  Tests for the Wagger.OauthCredentials context.
  """

  use Wagger.DataCase

  alias Wagger.OauthCredentials

  setup do
    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)
  end

  describe "upsert/3 and get/1" do
    test "stores client_id cleartext, secret locked, retrievable plaintext" do
      assert {:ok, _} = OauthCredentials.upsert("google", "id-1", "secret-1")
      assert {:ok, %{client_id: "id-1", client_secret: "secret-1"}} = OauthCredentials.get("google")

      row = Wagger.Repo.get_by!(Wagger.OauthCredentials.Credential, provider: "google")
      refute row.client_secret_locked == "secret-1"
      refute is_nil(row.client_secret_locked)
    end

    test "upsert overwrites existing credentials for a provider" do
      {:ok, _} = OauthCredentials.upsert("google", "id-old", "secret-old")
      {:ok, _} = OauthCredentials.upsert("google", "id-new", "secret-new")
      assert {:ok, %{client_id: "id-new", client_secret: "secret-new"}} =
               OauthCredentials.get("google")
    end

    test "get returns :error when nothing stored" do
      assert :error = OauthCredentials.get("github")
    end
  end

  describe "load_into_app_env/0" do
    test "writes Application env for google when row exists" do
      {:ok, _} = OauthCredentials.upsert("google", "id-loaded", "secret-loaded")
      :ok = OauthCredentials.load_into_app_env()

      cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      assert cfg[:client_id] == "id-loaded"
      assert cfg[:client_secret] == "secret-loaded"
    end

    test "seeds DB from env vars when no row exists" do
      System.put_env("GITHUB_OAUTH_CLIENT_ID", "envid")
      System.put_env("GITHUB_OAUTH_CLIENT_SECRET", "envsecret")

      try do
        :ok = OauthCredentials.load_into_app_env()
        assert {:ok, %{client_id: "envid", client_secret: "envsecret"}} =
                 OauthCredentials.get("github")

        cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
        assert cfg[:client_id] == "envid"
      after
        System.delete_env("GITHUB_OAUTH_CLIENT_ID")
        System.delete_env("GITHUB_OAUTH_CLIENT_SECRET")
      end
    end

    test "is a no-op for a provider with no row and no env vars" do
      :ok = OauthCredentials.load_into_app_env()
      assert is_nil(Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth))
    end
  end

  describe "provider_configured?/1" do
    test "true when credentials present, false otherwise" do
      refute OauthCredentials.provider_configured?("google")
      {:ok, _} = OauthCredentials.upsert("google", "id", "sec")
      assert OauthCredentials.provider_configured?("google")
    end
  end
end
