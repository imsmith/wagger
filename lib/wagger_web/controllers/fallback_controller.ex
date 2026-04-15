defmodule WaggerWeb.FallbackController do
  @moduledoc false

  use WaggerWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: WaggerWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: WaggerWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, %Comn.Errors.ErrorStruct{} = err}) do
    status = if err.code, do: Comn.Errors.Registry.http_status(err.code), else: nil
    status = status || 422

    conn
    |> put_status(status)
    |> json(%{error: err.message, code: err.code, reason: err.reason, field: err.field, suggestion: err.suggestion})
  end
end
