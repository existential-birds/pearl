defmodule Pearl.Release do
  @moduledoc """
  Release tasks for Pearl.

  Used by the Docker entrypoint to run migrations at container startup.

  ## Usage

      bin/pearl eval "Pearl.Release.migrate()"
  """

  @app :pearl

  @doc """
  Creates the database if it does not exist.

  Returns `:ok` whether the database was created or already existed.
  """
  @spec create_db() :: :ok
  def create_db do
    Application.load(@app)

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, reason} -> raise "Could not create database: #{inspect(reason)}"
      end
    end

    :ok
  end

  @doc """
  Runs all pending Ecto migrations.

  Returns `:ok` after all migrations complete. Safe to call repeatedly —
  already-applied migrations are skipped.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls back the given repo to the specified version.
  """
  @spec rollback(module(), integer()) :: {:ok, term(), term()}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.ensure_all_started(@app)
end
