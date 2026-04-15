defmodule Wagger.Secrets do
  @moduledoc """
  Encryption at rest for sensitive wagger data using Comn.Secrets.Local.

  Provides lock/unlock for snapshot outputs and route data.
  Uses an application-level Ed25519 key derived from a configured secret
  or auto-generated on first use.
  """

  alias Comn.Secrets.{Key, Local}

  @key_path "priv/secrets/wagger.key"

  @doc "Encrypts a binary string. Returns base64-encoded locked blob."
  def lock(plaintext) when is_binary(plaintext) do
    key = get_or_create_key()

    case Local.lock(plaintext, key) do
      {:ok, locked} ->
        {:ok, locked |> :erlang.term_to_binary() |> Base.encode64()}

      {:error, _} = err ->
        err
    end
  end

  @doc "Decrypts a base64-encoded locked blob. Returns plaintext."
  def unlock(encoded) when is_binary(encoded) do
    key = get_or_create_key()

    locked =
      encoded
      |> Base.decode64!()
      |> :erlang.binary_to_term([:safe])

    Local.unlock(locked, key)
  end

  @doc "Returns the current encryption key, generating one if none exists."
  def get_or_create_key do
    case read_key() do
      {:ok, key} -> key
      :error -> create_and_store_key()
    end
  end

  defp read_key do
    path = key_path()

    if File.exists?(path) do
      data = File.read!(path)
      {:ok, :erlang.binary_to_term(data, [:safe])}
    else
      :error
    end
  end

  defp create_and_store_key do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    key = %Key{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      algorithm: :ed25519,
      public: pub,
      private: priv
    }

    path = key_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(key))
    key
  end

  defp key_path do
    Application.get_env(:wagger, :secret_key_path, @key_path)
  end
end
