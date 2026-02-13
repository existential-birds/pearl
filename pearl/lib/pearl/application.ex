defmodule Pearl.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PearlWeb.Telemetry,
      Pearl.Repo,
      Pearl.Settings,
      {DNSCluster, query: Application.get_env(:pearl, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pearl.PubSub},
      # Start a worker by calling: Pearl.Worker.start_link(arg)
      # {Pearl.Worker, arg},
      {Task.Supervisor, name: Pearl.TaskSupervisor},
      # Start to serve requests, typically the last entry
      PearlWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Pearl.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Reset repos stuck in progress from a previous crash/restart
    try do
      Pearl.Repositories.reset_orphaned_repos()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Seed settings from environment variables (for Docker deployments)
    seed_settings_from_env()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PearlWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Seeds Pearl.Settings from environment variables.
  # Only writes if the env var is set AND the setting is still at its default.
  # This allows Docker users to configure via env vars without overriding
  # values that were previously set via the Settings UI.
  # Runs asynchronously so it doesn't block application startup if the
  # database is temporarily unavailable.
  defp seed_settings_from_env do
    Task.start(fn ->
      # Brief delay to let Repo connections stabilize
      Process.sleep(2_000)

      env_to_setting = [
        {"LLM_PROVIDER", "chat_provider"},
        {"LLM_MODEL", "chat_model"},
        {"EMBEDDING_MODEL", "embedding_model"}
      ]

      for {env_var, setting_key} <- env_to_setting do
        case System.get_env(env_var) do
          nil ->
            :ok

          "" ->
            :ok

          value ->
            try do
              defaults = Pearl.Settings.defaults()
              current = Pearl.Settings.get(setting_key)

              if current == Map.get(defaults, setting_key) do
                Pearl.Settings.put(setting_key, value)
              end
            rescue
              _ -> :ok
            catch
              :exit, _ -> :ok
            end
        end
      end
    end)
  end
end
