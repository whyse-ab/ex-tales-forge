defmodule TalesForge.Repo do
  # Upgraded to AshPostgres.Repo for Phase 2 authoring resources.
  # Continues to work as a standard Ecto.Repo for existing runtime schemas.
  use AshPostgres.Repo,
    otp_app: :ex_tales_forge,
    warn_on_missing_ash_functions?: false

  def installed_extensions do
    # Required for full AshPostgres features (atomics, string ops, ||/&&, etc.)
    ["ash-functions", "uuid-ossp"]
  end

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

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
