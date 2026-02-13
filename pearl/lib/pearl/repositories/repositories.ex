defmodule Pearl.Repositories do
  @moduledoc """
  The Repositories context handles git repository cloning and analysis.
  """

  require Logger

  import Ecto.Query
  alias Pearl.Repo
  alias Pearl.Repositories.{Git, RepoRecord}

  @spec create_repo(map()) :: {:ok, RepoRecord.t()} | {:error, Ecto.Changeset.t()}
  def create_repo(attrs) do
    %RepoRecord{}
    |> RepoRecord.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_repo(integer()) :: RepoRecord.t() | nil
  def get_repo(id), do: Repo.get(RepoRecord, id)

  @spec get_repo_by_url(String.t()) :: RepoRecord.t() | nil
  def get_repo_by_url(url) do
    Repo.get_by(RepoRecord, url: url)
  end

  @doc """
  Resets any repos stuck in an in-progress status to "failed".
  Called on application startup to recover from interrupted generations.
  """
  @spec reset_orphaned_repos() :: {non_neg_integer(), nil}
  def reset_orphaned_repos do
    in_progress = ~w(pending cloning analyzing generating)

    {count, _} =
      RepoRecord
      |> where([r], r.status in ^in_progress)
      |> Repo.update_all(set: [status: "failed", updated_at: NaiveDateTime.utc_now()])

    if count > 0 do
      Logger.info("Reset #{count} orphaned repo(s) to failed status on startup")
    end

    {count, nil}
  end

  @spec list_repos() :: [RepoRecord.t()]
  def list_repos do
    RepoRecord
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec search(String.t()) :: [RepoRecord.t()]
  def search(""), do: []

  def search(query) when is_binary(query) do
    pattern = "%#{query}%"

    RepoRecord
    |> where([r], ilike(r.owner, ^pattern) or ilike(r.name, ^pattern))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec update_status(RepoRecord.t(), String.t()) ::
          {:ok, RepoRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_status(repo, status) do
    repo
    |> RepoRecord.changeset(%{status: status})
    |> Repo.update()
  end

  @spec update_repo(RepoRecord.t(), map()) :: {:ok, RepoRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_repo(repo, attrs) do
    repo
    |> RepoRecord.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_repo(RepoRecord.t()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def delete_repo(%RepoRecord{} = repo) do
    case delete_repo_files(repo) do
      :ok -> Repo.delete(repo)
      {:error, reason} -> {:error, {:file_deletion_failed, reason}}
    end
  end

  defp delete_repo_files(%RepoRecord{local_path: nil}), do: :ok

  defp delete_repo_files(%RepoRecord{local_path: path}) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @spec clone(String.t(), keyword()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def clone(url, opts \\ []) do
    with {:ok, parsed} <- Git.parse_url(url),
         {:ok, repo} <- find_or_create_repo(url, parsed),
         {:ok, repo} <- update_status(repo, "cloning"),
         target_path = repo_path(repo),
         metadata = fetch_metadata(repo),
         :ok <- ensure_parent_dir(target_path),
         {:ok, _} <- Git.clone(url, target_path, opts),
         {:ok, files} <- Git.list_files(target_path),
         attrs =
           Map.merge(metadata, %{
             local_path: target_path,
             file_count: length(files),
             status: "ready"
           }),
         {:ok, repo} <- update_repo(repo, attrs) do
      {:ok, repo}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Clones a repository when the repo record already exists.
  Does NOT fetch metadata since it's done in parallel for faster card display.
  """
  @spec clone_existing(RepoRecord.t(), keyword()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def clone_existing(%RepoRecord{} = repo, opts \\ []) do
    with {:ok, repo} <- update_status(repo, "cloning"),
         target_path = repo_path(repo),
         :ok <- ensure_parent_dir(target_path),
         :ok <- maybe_remove_existing(target_path),
         {:ok, _} <- Git.clone(repo.url, target_path, opts),
         {:ok, files} <- Git.list_files(target_path),
         attrs = %{
           local_path: target_path,
           file_count: length(files),
           status: "ready"
         },
         {:ok, repo} <- update_repo(repo, attrs) do
      {:ok, repo}
    end
  end

  defp maybe_remove_existing(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, {:cleanup_failed, reason}}
      end
    else
      :ok
    end
  end

  @doc """
  Fetches metadata from GitHub/GitLab API and saves to DB.
  Used for async metadata fetching for faster card display.
  """
  @spec fetch_and_save_metadata(RepoRecord.t()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def fetch_and_save_metadata(%RepoRecord{} = repo) do
    metadata = fetch_metadata(repo)

    if map_size(metadata) > 0 do
      update_repo(repo, metadata)
    else
      {:ok, repo}
    end
  end

  defp fetch_metadata(%RepoRecord{provider: "github", owner: owner, name: name}) do
    url = "https://api.github.com/repos/#{owner}/#{name}"
    headers = [{"accept", "application/vnd.github.v3+json"}, {"user-agent", "Pearl-Wiki"}]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        %{
          description: data["description"],
          stars: data["stargazers_count"],
          language: data["language"],
          pushed_at: parse_datetime(data["pushed_at"])
        }

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GitHub API returned #{status} for #{owner}/#{name}: #{inspect(body)}")
        %{}

      {:error, reason} ->
        Logger.warning("GitHub API request failed for #{owner}/#{name}: #{inspect(reason)}")
        %{}
    end
  end

  defp fetch_metadata(%RepoRecord{provider: "gitlab", owner: owner, name: name}) do
    url = "https://gitlab.com/api/v4/projects/#{URI.encode_www_form("#{owner}/#{name}")}"
    headers = [{"user-agent", "Pearl-Wiki"}]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        %{
          description: data["description"],
          stars: data["star_count"],
          language: nil,
          pushed_at: parse_datetime(data["last_activity_at"])
        }

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GitLab API returned #{status} for #{owner}/#{name}: #{inspect(body)}")
        %{}

      {:error, reason} ->
        Logger.warning("GitLab API request failed for #{owner}/#{name}: #{inspect(reason)}")
        %{}
    end
  end

  defp fetch_metadata(_repo), do: %{}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp find_or_create_repo(url, parsed) do
    case get_repo_by_url(url) do
      nil ->
        create_repo(Map.put(parsed, :url, url))

      existing ->
        {:ok, existing}
    end
  end

  defp repo_path(repo) do
    base = Pearl.Config.repos_path() |> Path.expand()
    Path.join([base, repo.provider, repo.owner, repo.name])
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  @spec flatten_structure(map(), String.t()) :: [String.t()]
  def flatten_structure(structure, prefix \\ "") do
    Enum.flat_map(structure, fn
      {name, :file} ->
        [Path.join(prefix, name)]

      {name, children} when is_map(children) ->
        flatten_structure(children, Path.join(prefix, name))
    end)
  end

  @spec get_structure(RepoRecord.t()) :: {:ok, map()} | {:error, term()}
  def get_structure(%RepoRecord{local_path: nil}), do: {:error, :not_cloned}

  def get_structure(%RepoRecord{local_path: path}) do
    case Git.list_files(path) do
      {:ok, files} ->
        structure = build_tree(files)
        {:ok, structure}

      error ->
        error
    end
  end

  defp build_tree(files) do
    Enum.reduce(files, %{}, fn file, acc ->
      parts = Path.split(file)
      put_in_nested(acc, parts)
    end)
  end

  defp put_in_nested(map, [file]) do
    Map.put(map, file, :file)
  end

  defp put_in_nested(map, [dir | rest]) do
    current = Map.get(map, dir, %{})
    Map.put(map, dir, put_in_nested(current, rest))
  end

  @spec read_file(RepoRecord.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(%RepoRecord{local_path: nil}, _path), do: {:error, :not_cloned}

  def read_file(%RepoRecord{local_path: repo_path}, file_path) do
    repo_root = Path.expand(repo_path)
    full_path = Path.expand(file_path, repo_root)

    with {false, _} <- {".." in Path.split(file_path), :path_traversal},
         {true, _} <- {String.starts_with?(full_path, repo_root <> "/"), :path_traversal},
         {:ok, info} <- File.lstat(full_path),
         {false, _} <- {info.type == :symlink, :symlink_rejected} do
      File.read(full_path)
    else
      {bool, reason} when is_boolean(bool) and is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
