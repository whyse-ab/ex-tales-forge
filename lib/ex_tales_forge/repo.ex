defmodule TalesForge.Repo do
  @moduledoc """
  The Postgres repo (plain `Ecto.Repo`).
  """

  use Ecto.Repo,
    otp_app: :ex_tales_forge,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Insert whose failure never aborts an enclosing transaction: inside one it runs
  under a savepoint (a nested `transaction/1` would not); outside one, plainly,
  since `mode: :savepoint` there fails with "transaction is not started".
  """
  def insert_isolated(changeset) do
    opts = if in_transaction?(), do: [mode: :savepoint], else: []
    insert(changeset, opts)
  end
end
