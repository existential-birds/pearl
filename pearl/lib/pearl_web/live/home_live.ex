defmodule PearlWeb.HomeLive do
  @moduledoc """
  LiveView for the home page displaying repository list and clone form.
  """
  use PearlWeb, :live_view

  alias Pearl.Repositories
  alias Pearl.Repositories.Git

  @impl true
  def mount(_params, _session, socket) do
    # Trap exits to handle linked task crashes gracefully
    Process.flag(:trap_exit, true)
    repos = Repositories.list_repos()

    {:ok,
     assign(socket,
       page_title: "Pearl",
       drawer_id: nil,
       breadcrumb: nil,
       show_ask: false,
       repos: repos,
       repo_url: "",
       generating: false,
       progress_by_repo: %{},
       error: nil,
       confirm_delete_id: nil,
       linked_tasks: MapSet.new()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="max-w-6xl mx-auto py-12 px-4">
        <div class="card bg-base-100 shadow-md mb-8">
          <div class="card-body">
            <form phx-submit="generate" class="space-y-6">
              <div class="form-control">
                <label for="repo_url" class="label">
                  <span class="label-text">Repository URL</span>
                </label>
                <input
                  type="url"
                  name="repo_url"
                  id="repo_url"
                  value={@repo_url}
                  placeholder="https://github.com/owner/repo"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <%= if @error do %>
                <div role="alert" class="alert alert-error">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-6 w-6 shrink-0 stroke-current"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>{@error}</span>
                </div>
              <% end %>

              <button type="submit" disabled={@generating} class="btn btn-primary w-full">
                {if @generating, do: "Generating...", else: "Generate Wiki"}
              </button>
            </form>
          </div>
        </div>

        <%= if length(@repos) > 0 do %>
          <div>
            <h2 class="text-xl font-semibold mb-6">Recent Repositories</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
              <%= for {repo, idx} <- Enum.with_index(@repos) do %>
                <div
                  class={[
                    "card bg-base-100 shadow-md border-l-4 hover:-translate-y-1 transition-transform duration-200 animate-fade-up",
                    status_border(repo.status)
                  ]}
                  style={"animation-delay: #{idx * 75}ms"}
                >
                  <div class="card-body p-5">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-3">
                        <div class="avatar">
                          <div class="w-10 rounded-full">
                            <img src={avatar_url(repo)} alt={repo.owner} />
                          </div>
                        </div>
                        <div class="min-w-0">
                          <h3 class="font-bold text-base truncate">{repo.name}</h3>
                          <.link
                            href={repo.url}
                            target="_blank"
                            class="text-xs link link-primary opacity-70"
                          >
                            {repo.owner}/{repo.name}
                          </.link>
                        </div>
                      </div>
                      <div class="flex items-center gap-1">
                        <%= if @confirm_delete_id == repo.id do %>
                          <button
                            phx-click="confirm_delete"
                            phx-value-id={repo.id}
                            class="btn btn-error btn-xs"
                          >
                            Delete
                          </button>
                          <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                            Cancel
                          </button>
                        <% else %>
                          <button
                            phx-click="request_delete"
                            phx-value-id={repo.id}
                            class="btn btn-ghost btn-xs text-error hover:bg-error hover:text-error-content"
                            disabled={
                              repo.status in ["cloning", "analyzing", "generating", "pending"] or
                                Map.has_key?(@progress_by_repo, repo.id)
                            }
                          >
                            <.icon name="hero-trash" class="size-4" />
                          </button>
                        <% end %>
                      </div>
                    </div>

                    <%= if progress = @progress_by_repo[repo.id] do %>
                      <div class="flex items-center gap-2 mt-3 text-sm text-warning">
                        <span class="loading loading-spinner loading-sm"></span>
                        <span class="truncate">{progress}</span>
                      </div>
                    <% else %>
                      <%= if repo.description do %>
                        <p class="text-sm opacity-70 mt-3 line-clamp-2">{repo.description}</p>
                      <% else %>
                        <p class="text-sm opacity-40 mt-3 italic">No description</p>
                      <% end %>
                    <% end %>

                    <div class="flex flex-wrap items-center gap-2 mt-auto pt-3">
                      <%= if repo.stars do %>
                        <span class="badge badge-sm badge-outline gap-1">
                          <.icon name="hero-star" class="size-3" />
                          {format_number(repo.stars)}
                        </span>
                      <% end %>
                      <%= if repo.language do %>
                        <span class="badge badge-sm badge-outline gap-1">
                          <span class={"w-2 h-2 rounded-full #{language_color(repo.language)}"}>
                          </span>
                          {repo.language}
                        </span>
                      <% end %>
                      <span class={"badge badge-sm #{status_badge(repo.status)}"}>{repo.status}</span>
                    </div>

                    <%= if repo.pushed_at do %>
                      <div class="text-xs opacity-50 mt-2">
                        Updated {format_date(repo.pushed_at)}
                      </div>
                    <% end %>

                    <div class="card-actions mt-3">
                      <%= if repo.status == "ready" do %>
                        <.link navigate={~p"/wiki/#{repo.id}"} class="btn btn-primary btn-sm w-full">
                          View Wiki
                        </.link>
                      <% else %>
                        <button class="btn btn-sm w-full" disabled>
                          {status_button_text(repo.status)}
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="text-center py-16 opacity-50">
            <.icon name="hero-folder-open" class="size-12 mx-auto mb-4" />
            <p class="text-lg">No repositories yet</p>
            <p class="text-sm mt-1">Paste a GitHub URL above to generate your first wiki.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("generate", %{"repo_url" => url}, socket) do
    case Git.parse_url(url) do
      {:ok, parsed} ->
        case find_or_create_pending_repo(url, parsed) do
          {:ok, repo} ->
            repos = prepend_or_update_repo(socket.assigns.repos, repo)
            progress_by_repo = Map.put(socket.assigns.progress_by_repo, repo.id, "Starting...")

            socket =
              assign(socket,
                repos: repos,
                generating: true,
                progress_by_repo: progress_by_repo,
                error: nil,
                repo_url: ""
              )

            pid = self()
            repo_id = repo.id

            # Fetch metadata in parallel (for instant card display with full info)
            # Linked to LiveView - terminates if user navigates away
            {:ok, metadata_pid} =
              Task.Supervisor.start_child(
                Pearl.TaskSupervisor,
                fn -> fetch_metadata_task(pid, repo_id, repo) end,
                link: true
              )

            # Main generation task
            # Linked to LiveView - terminates if user navigates away
            # If this fails to start, kill the metadata task to avoid orphans
            generation_result =
              Task.Supervisor.start_child(
                Pearl.TaskSupervisor,
                fn -> generate_wiki_task(pid, repo_id, repo) end,
                link: true
              )

            case generation_result do
              {:ok, generation_pid} ->
                socket = assign(socket, linked_tasks: MapSet.new([metadata_pid, generation_pid]))
                {:noreply, socket}

              {:error, reason} ->
                Process.exit(metadata_pid, :shutdown)
                {:noreply, assign(socket, generating: false, error: format_error(reason))}
            end

          {:error, reason} ->
            {:noreply, assign(socket, error: format_error(reason))}
        end

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} -> {:noreply, assign(socket, confirm_delete_id: int_id)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {repo_id, ""} ->
        case Repositories.get_repo(repo_id) do
          nil ->
            {:noreply,
             socket |> assign(confirm_delete_id: nil) |> put_flash(:error, "Repository not found")}

          repo ->
            case Repositories.delete_repo(repo) do
              {:ok, deleted} ->
                {:noreply,
                 socket
                 |> assign(
                   repos: Enum.reject(socket.assigns.repos, &(&1.id == repo_id)),
                   confirm_delete_id: nil
                 )
                 |> put_flash(:info, "Deleted #{deleted.owner}/#{deleted.name}")}

              {:error, _} ->
                {:noreply,
                 socket
                 |> assign(confirm_delete_id: nil)
                 |> put_flash(:error, "Failed to delete repository")}
            end
        end

      _ ->
        {:noreply, assign(socket, confirm_delete_id: nil)}
    end
  end

  @impl true
  def handle_info({:progress, repo_id, message}, socket) do
    progress_by_repo = Map.put(socket.assigns.progress_by_repo, repo_id, message)
    {:noreply, assign(socket, progress_by_repo: progress_by_repo)}
  end

  @impl true
  def handle_info({:metadata_updated, repo_id, updated_repo}, socket) do
    repos = update_repo_in_list(socket.assigns.repos, repo_id, fn _old -> updated_repo end)
    {:noreply, assign(socket, repos: repos)}
  end

  @impl true
  def handle_info({:generation_complete, repo_id, {:ok, repo}}, socket) do
    repos =
      update_repo_in_list(socket.assigns.repos, repo_id, fn _ ->
        %{repo | status: "ready"}
      end)

    {:noreply,
     socket
     |> assign(
       generating: false,
       repos: repos,
       progress_by_repo: Map.delete(socket.assigns.progress_by_repo, repo_id)
     )
     |> push_navigate(to: ~p"/wiki/#{repo.id}")}
  end

  @impl true
  def handle_info({:generation_complete, repo_id, {:error, reason}}, socket) do
    repos =
      update_repo_in_list(socket.assigns.repos, repo_id, fn repo ->
        %{repo | status: "failed"}
      end)

    {:noreply,
     assign(socket,
       generating: false,
       repos: repos,
       progress_by_repo: Map.delete(socket.assigns.progress_by_repo, repo_id),
       error: format_error(reason)
     )}
  end

  @impl true
  def handle_info({:EXIT, pid, :normal}, socket) do
    {:noreply, assign(socket, linked_tasks: MapSet.delete(socket.assigns.linked_tasks, pid))}
  end

  @impl true
  def handle_info({:EXIT, pid, :shutdown}, socket) do
    {:noreply, assign(socket, linked_tasks: MapSet.delete(socket.assigns.linked_tasks, pid))}
  end

  @impl true
  def handle_info({:EXIT, pid, {:shutdown, _}}, socket) do
    {:noreply, assign(socket, linked_tasks: MapSet.delete(socket.assigns.linked_tasks, pid))}
  end

  @impl true
  def handle_info({:EXIT, crashed_pid, reason}, socket) do
    # A linked task crashed - terminate sibling tasks and clear generating state
    socket.assigns.linked_tasks
    |> MapSet.delete(crashed_pid)
    |> Enum.each(&Process.exit(&1, :shutdown))

    {:noreply,
     assign(socket,
       generating: false,
       progress_by_repo: %{},
       linked_tasks: MapSet.new(),
       error: "Task failed unexpectedly: #{inspect(reason)}"
     )}
  end

  @doc false
  # Task entry point for Task.Supervisor.start_child - fetches repo metadata
  def fetch_metadata_task(pid, repo_id, repo) do
    case Repositories.fetch_and_save_metadata(repo) do
      {:ok, updated_repo} -> send(pid, {:metadata_updated, repo_id, updated_repo})
      _ -> :ok
    end
  end

  @doc false
  # Task entry point for Task.Supervisor.start_child - generates wiki
  def generate_wiki_task(pid, repo_id, repo) do
    result = do_generate(repo, fn msg -> send(pid, {:progress, repo_id, msg}) end)
    send(pid, {:generation_complete, repo_id, result})
  end

  defp do_generate(%Pearl.Repositories.RepoRecord{id: repo_id} = repo, on_progress) do
    on_progress.("Cloning repository...")

    with {:ok, repo} <- Repositories.clone_existing(repo),
         _ <- on_progress.("Repository cloned. Indexing for RAG..."),
         {:ok, count} <- Pearl.Rag.index_repo(repo),
         _ <- on_progress.("Indexed #{count} chunks. Generating wiki..."),
         {:ok, repo} <- Repositories.update_status(repo, "generating"),
         {:ok, _wiki_data} <- Pearl.Wiki.generate(repo, on_progress),
         {:ok, repo} <- Repositories.update_status(repo, "ready") do
      {:ok, repo}
    else
      {:error, {:clone_failed, output}} ->
        {:error, {:clone_failed, "Git clone failed: #{String.slice(output, 0, 200)}"}}

      {:error, reason} ->
        # Fetch fresh repo to avoid stale struct issues when marking as failed
        case Repositories.get_repo(repo_id) do
          nil -> :ok
          fresh_repo -> Repositories.update_status(fresh_repo, "failed")
        end

        {:error, reason}
    end
  end

  defp find_or_create_pending_repo(url, parsed) do
    case Repositories.get_repo_by_url(url) do
      nil ->
        Repositories.create_repo(Map.merge(parsed, %{url: url, status: "pending"}))

      existing ->
        Repositories.update_status(existing, "pending")
    end
  end

  defp prepend_or_update_repo(repos, repo) do
    case Enum.find_index(repos, &(&1.id == repo.id)) do
      nil -> [repo | repos]
      idx -> List.replace_at(repos, idx, repo)
    end
  end

  defp update_repo_in_list(repos, repo_id, update_fn) do
    Enum.map(repos, fn repo ->
      if repo.id == repo_id, do: update_fn.(repo), else: repo
    end)
  end

  defp format_error({:clone_failed, msg}), do: "Clone failed: #{msg}"
  defp format_error({:indexing_failed, msg}), do: "Indexing failed: #{inspect(msg)}"
  defp format_error({:generation_failed, msg}), do: "Wiki generation failed: #{inspect(msg)}"
  defp format_error(:invalid_url), do: "Invalid repository URL format"

  defp format_error(:unsupported_provider),
    do: "Only GitHub, GitLab, and Bitbucket URLs are supported"

  defp format_error(msg) when is_binary(msg), do: msg
  defp format_error(msg), do: "Error: #{inspect(msg)}"

  defp status_badge("ready"), do: "badge-success"
  defp status_badge("pending"), do: "badge-warning"
  defp status_badge("cloning"), do: "badge-warning"
  defp status_badge("analyzing"), do: "badge-warning"
  defp status_badge("generating"), do: "badge-info"
  defp status_badge("failed"), do: "badge-error"
  defp status_badge(_), do: "badge-neutral"

  defp status_border("ready"), do: "border-success"
  defp status_border("pending"), do: "border-warning"
  defp status_border("cloning"), do: "border-warning"
  defp status_border("analyzing"), do: "border-warning"
  defp status_border("generating"), do: "border-info"
  defp status_border("failed"), do: "border-error"
  defp status_border(_), do: "border-neutral"

  defp status_button_text("pending"), do: "Starting..."
  defp status_button_text("generating"), do: "Generating..."
  defp status_button_text("cloning"), do: "Cloning..."
  defp status_button_text("analyzing"), do: "Analyzing..."
  defp status_button_text(_), do: "View Wiki"

  defp avatar_url(%{provider: "github", owner: owner}),
    do: "https://github.com/#{owner}.png?size=64"

  defp avatar_url(%{provider: "gitlab", owner: owner}),
    do: "https://api.dicebear.com/7.x/identicon/svg?seed=#{owner}"

  defp avatar_url(_), do: "https://api.dicebear.com/7.x/identicon/svg?seed=repo"

  defp format_number(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_number(n), do: to_string(n)

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp language_color("Elixir"), do: "bg-purple-500"
  defp language_color("Python"), do: "bg-blue-500"
  defp language_color("JavaScript"), do: "bg-yellow-400"
  defp language_color("TypeScript"), do: "bg-blue-600"
  defp language_color("Ruby"), do: "bg-red-600"
  defp language_color("Go"), do: "bg-cyan-500"
  defp language_color("Rust"), do: "bg-orange-600"
  defp language_color("Java"), do: "bg-orange-500"
  defp language_color("C"), do: "bg-gray-600"
  defp language_color("C++"), do: "bg-pink-600"
  defp language_color("Swift"), do: "bg-orange-500"
  defp language_color("Kotlin"), do: "bg-purple-600"
  defp language_color(_), do: "bg-gray-400"
end
