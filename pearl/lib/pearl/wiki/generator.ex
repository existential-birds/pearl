defmodule Pearl.Wiki.Generator do
  @moduledoc """
  Orchestrates wiki generation from a repository.
  """

  require Logger

  alias Pearl.Wiki.Prompts
  alias Pearl.Providers
  alias Pearl.Repositories
  alias Pearl.Repositories.RepoRecord

  @type progress_callback :: (String.t() -> any())
  @type page_type :: :overview | :getting_started | :architecture | :configuration | :default

  # High-priority files for different page types
  @getting_started_files ~w(README.md readme.md pyproject.toml package.json mix.exs Cargo.toml setup.py setup.cfg Gemfile go.mod requirements.txt INSTALL.md install.md)
  @architecture_files ~w(main.py app.py index.ts index.js lib/app.ex application.ex router.ex endpoint.ex main.rs lib.rs mod.rs)
  @config_files ~w(config.exs runtime.exs dev.exs prod.exs .env.example config.json config.yaml config.yml settings.py)

  @spec generate(RepoRecord.t(), atom(), String.t(), progress_callback()) ::
          {:ok, map()} | {:error, term()}
  def generate(%RepoRecord{} = repo, provider, model, on_progress \\ fn _ -> :ok end) do
    # Also broadcast via PubSub for subscribers
    broadcast_progress = fn msg ->
      on_progress.(msg)
      Phoenix.PubSub.broadcast(Pearl.PubSub, "wiki:#{repo.id}", {:progress, msg})
    end

    with {:ok, structure} <- Repositories.get_structure(repo),
         _ <- broadcast_progress.("Analyzing repository structure..."),
         {:ok, wiki_structure} <-
           generate_structure(structure, provider, model, cd: repo.local_path),
         _ <- broadcast_progress.("Generating #{length(wiki_structure["pages"])} pages..."),
         {:ok, pages} <-
           generate_pages(repo, structure, wiki_structure, provider, model, broadcast_progress) do
      Phoenix.PubSub.broadcast(Pearl.PubSub, "wiki:#{repo.id}", {:complete, wiki_structure})
      {:ok, %{structure: wiki_structure, pages: pages, model_used: "#{provider}/#{model}"}}
    end
  end

  defp generate_structure(file_tree, provider, model, opts) do
    messages = Prompts.structure_prompt(file_tree)

    case Providers.chat(provider, model, messages, [stream: false] ++ opts) do
      {:ok, response} -> parse_structure_response(response)
      error -> error
    end
  end

  @spec parse_structure_response(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_structure_response(response) do
    # Strip markdown code blocks if present
    json =
      response
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    case Jason.decode(json) do
      {:ok, %{"pages" => _} = parsed} ->
        {:ok, parsed}

      {:ok, _} ->
        {:error, :invalid_structure}

      {:error, _} ->
        # Fallback: extract JSON object from text with LLM preamble
        case extract_json_object(json) do
          nil ->
            {:error, {:json_parse_error, :no_json_found}}

          extracted ->
            case Jason.decode(extracted) do
              {:ok, %{"pages" => _} = parsed} -> {:ok, parsed}
              {:ok, _} -> {:error, :invalid_structure}
              {:error, reason} -> {:error, {:json_parse_error, reason}}
            end
        end
    end
  end

  defp extract_json_object(text) do
    case Regex.run(~r/\{.+\}/s, text) do
      [match] -> match
      _ -> nil
    end
  end

  defp generate_pages(repo, structure, wiki_structure, provider, model, on_progress) do
    total = length(wiki_structure["pages"])

    {pages, errors} =
      wiki_structure["pages"]
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {page_spec, index} ->
          on_progress.("Generating page #{index}/#{total}: #{page_spec["title"]}...")

          case generate_page(repo, structure, page_spec, provider, model) do
            {:ok, content} ->
              {:ok, {page_spec["id"], content}}

            {:error, reason} ->
              Logger.error(
                "Failed to generate wiki page '#{page_spec["id"]}' for repo #{repo.id}: #{inspect(reason)}"
              )

              {:error, page_spec["id"]}
          end
        end,
        max_concurrency: 4,
        timeout: Pearl.Config.wiki_page_timeout()
      )
      |> Enum.reduce({%{}, []}, fn
        {:ok, {:ok, {page_id, content}}}, {pages, errors} ->
          {Map.put(pages, page_id, content), errors}

        {:ok, {:error, page_id}}, {pages, errors} ->
          {pages, [page_id | errors]}

        {:exit, reason}, {pages, errors} ->
          Logger.error("Wiki page generation task crashed: #{inspect(reason)}")
          {pages, [{:task_crashed, reason} | errors]}
      end)

    case errors do
      [] -> {:ok, pages}
      failed_pages -> {:error, {:page_generation_failed, Enum.reverse(failed_pages)}}
    end
  end

  defp generate_page(repo, structure, page_spec, provider, model) do
    all_files = Repositories.flatten_structure(structure)

    page_type = determine_page_type(page_spec)
    keywords = extract_keywords(page_spec)

    # Score and select the most relevant files for this page
    files =
      all_files
      |> score_files(page_type, keywords)
      |> Enum.sort_by(fn {_path, score} -> score end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {path, _score} -> path end)

    file_contents =
      Enum.flat_map(files, fn path ->
        case Repositories.read_file(repo, path) do
          {:ok, content} -> [{path, content}]
          _ -> []
        end
      end)

    page_spec_map = %{
      id: page_spec["id"],
      title: page_spec["title"],
      description: page_spec["description"]
    }

    messages = Prompts.page_prompt(page_spec_map, file_contents, page_type)

    case Providers.chat(provider, model, messages, stream: false, cd: repo.local_path) do
      {:ok, content} -> {:ok, content}
      error -> error
    end
  end

  @doc """
  Determines the page type from a page specification based on its id and title.
  """
  @spec determine_page_type(map()) :: page_type()
  def determine_page_type(page_spec) do
    id = String.downcase(page_spec["id"] || "")
    title = String.downcase(page_spec["title"] || "")
    combined = "#{id} #{title}"

    cond do
      String.contains?(combined, "overview") ->
        :overview

      Enum.any?(
        ~w(getting-started installation quickstart setup),
        &String.contains?(combined, &1)
      ) ->
        :getting_started

      Enum.any?(~w(architecture design structure), &String.contains?(combined, &1)) ->
        :architecture

      Enum.any?(~w(config configuration settings), &String.contains?(combined, &1)) ->
        :configuration

      true ->
        :default
    end
  end

  @doc """
  Extracts keywords from a page specification for relevance scoring.
  """
  @spec extract_keywords(map()) :: [String.t()]
  def extract_keywords(page_spec) do
    id = page_spec["id"] || ""
    title = page_spec["title"] || ""
    description = page_spec["description"] || ""

    "#{id} #{title} #{description}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @doc """
  Scores files by relevance to a page type and keywords.
  Returns a list of {path, score} tuples.
  """
  @spec score_files([String.t()], page_type(), [String.t()]) :: [{String.t(), integer()}]
  def score_files(files, page_type, keywords) do
    Enum.map(files, fn path ->
      filename = Path.basename(path)
      path_lower = String.downcase(path)

      # Score based on page type
      type_score =
        case page_type do
          :getting_started ->
            if Enum.any?(@getting_started_files, &(filename == &1)), do: 100, else: 0

          :architecture ->
            cond do
              Enum.any?(@architecture_files, &String.ends_with?(path, &1)) -> 100
              String.contains?(path_lower, "router") -> 80
              String.contains?(path_lower, "endpoint") -> 80
              String.contains?(path_lower, "application") -> 70
              true -> 0
            end

          :configuration ->
            cond do
              Enum.any?(@config_files, &(filename == &1)) -> 100
              String.contains?(path_lower, "config") -> 80
              String.contains?(path_lower, "settings") -> 70
              true -> 0
            end

          :overview ->
            cond do
              filename == "README.md" or filename == "readme.md" -> 100
              Enum.any?(@getting_started_files, &(filename == &1)) -> 50
              true -> 0
            end

          :default ->
            0
        end

      # Score based on keyword matching
      keyword_score =
        keywords
        |> Enum.count(fn keyword ->
          String.contains?(path_lower, keyword)
        end)
        |> Kernel.*(20)

      # Bonus for commonly important files
      importance_score =
        cond do
          filename == "README.md" or filename == "readme.md" -> 30
          String.ends_with?(filename, ".ex") -> 10
          String.ends_with?(filename, ".py") -> 10
          String.ends_with?(filename, ".ts") or String.ends_with?(filename, ".js") -> 10
          String.ends_with?(filename, ".rs") -> 10
          true -> 0
        end

      {path, type_score + keyword_score + importance_score}
    end)
  end
end
