defmodule Oban.Met.Migration do
  @moduledoc """
  Migrations that add estimate functionality.

  > #### Migrations Are Not Required {: .tip}
  >
  > Met will create the necessary estimate function automatically when possible. This migration
  > isn't necessary under normal circumstances, but is provided to avoid permission issues or
  > allow full control over database changes.
  >
  > See the section on [Explicit Migrations](installation.html) for more information.

  ## Usage

  To use migrations in your application you'll need to generate an `Ecto.Migration` that wraps
  calls to `Oban.Met.Migration`:

  ```bash
  mix ecto.gen.migration add_oban_met
  ```

  Open the generated migration and delegate the `up/0` and `down/0` functions to
  `Oban.Met.Migration`:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddObanMet do
    use Ecto.Migration

    def up, do: Oban.Met.Migration.up()

    def down, do: Oban.Met.Migration.down()
  end
  ```

  This will run all of the necessary migrations for your database.
  """

  use Ecto.Migration

  @doc """
  Run the `up` migration.

  ## Example

  Run all migrations up to the current version:

      Oban.Met.Migration.up()

  Run migrations in an alternate prefix:

      Oban.Met.Migration.up(prefix: "payments")
  """
  def up(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:prefix, "public")
    |> oban_count_estimate()
    |> execute()
  end

  @doc """
  Run the `down` migration.

  ## Example

  Run all migrations up to the current version:

      Oban.Met.Migration.down()

  Run migrations in an alternate prefix:

      Oban.Met.Migration.down(prefix: "payments")
  """
  def down(opts \\ []) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix, "public")

    execute "DROP FUNCTION IF EXISTS #{prefix}.oban_count_estimate(text, text)"
  end

  # An `EXPLAIN` can only be executed as the top level of a query, or through an SQL function's
  # EXECUTE as we're doing here. A named function helps the performance because it is prepared,
  # and we have to support distributed databases that don't allow DO/END functions.
  @doc false
  def oban_count_estimate(prefix) do
    """
    CREATE OR REPLACE FUNCTION #{prefix}.oban_count_estimate(state text, queue text)
    RETURNS integer AS $func$
    DECLARE
      plan jsonb;
    BEGIN
      EXECUTE 'EXPLAIN (FORMAT JSON)
               SELECT id
               FROM #{prefix}.oban_jobs
               WHERE state = $1::#{prefix}.oban_job_state
               AND queue = $2'
        INTO plan
        USING state, queue;
      RETURN plan->0->'Plan'->'Plan Rows';
    END;
    $func$
    LANGUAGE plpgsql 
    """
  end
end
