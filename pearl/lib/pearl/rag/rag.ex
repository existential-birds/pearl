defmodule Pearl.Rag do
  @moduledoc """
  The Rag context handles embeddings and retrieval-augmented generation.
  """

  @behaviour Pearl.Rag.Behaviour

  require Logger

  import Ecto.Query
  alias Pearl.Config
  alias Pearl.Repo
  alias Pearl.Rag.{Chunker, Embedding}
  alias Pearl.Repositories
  alias Pearl.Repositories.RepoRecord
  alias Pearl.Providers

  # Max characters for history (leaves room for system prompt + RAG context + current question)
  @max_history_chars 8_000

  @doc "Creates a new embedding record in the database."
  @spec create_embedding(map()) :: {:ok, Embedding.t()} | {:error, Ecto.Changeset.t()}
  def create_embedding(attrs) do
    %Embedding{}
    |> Embedding.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Deletes all embedding records for the given repository."
  @spec delete_embeddings_for_repo(integer()) :: {non_neg_integer(), nil}
  def delete_embeddings_for_repo(repo_id) do
    Embedding
    |> where([e], e.repo_id == ^repo_id)
    |> Repo.delete_all()
  end

  @typep index_opts :: [batch_size: pos_integer(), file_concurrency: pos_integer()]

  @doc """
  Indexes a repository by chunking its files and generating vector embeddings.

  Reads all tracked files, splits them into chunks, embeds them in batches,
  and stores the results in the database for later similarity search.
  """
  @spec index_repo(RepoRecord.t(), index_opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def index_repo(%RepoRecord{} = repo, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, Config.embedding_batch_size())
    concurrency = Keyword.get(opts, :file_concurrency, Config.file_read_concurrency())

    with {:ok, structure} <- Repositories.get_structure(repo) do
      files = Repositories.flatten_structure(structure)

      # Delete existing embeddings first
      delete_embeddings_for_repo(repo.id)

      # Process files with streaming pipeline:
      # 1. Read files in parallel (Task.async_stream)
      # 2. Lazily chunk results (Stream.flat_map)
      # 3. Batch for embedding API (Stream.chunk_every)
      # 4. Reduce to count
      {count, failed?} =
        files
        |> stream_file_chunks(repo, concurrency)
        |> Stream.chunk_every(batch_size)
        |> Enum.reduce({0, false}, &process_batch(repo.id, &1, &2))

      # Save the embedding model used for this repo
      Repositories.update_repo(repo, %{embedding_model: Config.embedding_model()})

      if failed?, do: {:error, :embedding_failed}, else: {:ok, count}
    end
  end

  defp stream_file_chunks(files, repo, concurrency) do
    files
    |> Task.async_stream(
      fn path -> read_and_chunk_file(repo, path) end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.flat_map(fn
      {:ok, chunks} ->
        chunks

      {:exit, reason} ->
        Logger.warning("File processing failed or timed out: #{inspect(reason)}")
        []
    end)
  end

  defp read_and_chunk_file(repo, file_path) do
    case Repositories.read_file(repo, file_path) do
      {:ok, content} -> Chunker.chunk_file(file_path, content)
      _ -> []
    end
  end

  defp process_batch(repo_id, batch, {acc, failed?}) do
    case embed_and_store_batch(repo_id, batch) do
      {:ok, n} ->
        {acc + n, failed?}

      {:error, reason} ->
        Logger.warning("Batch embedding failed: #{inspect(reason)}")
        {acc, true}
    end
  end

  defp embed_and_store_batch(repo_id, chunks) do
    texts = Enum.map(chunks, & &1.content)

    case Providers.embed(Config.embedding_provider(), texts) do
      {:ok, vectors} ->
        entries =
          Enum.zip(chunks, vectors)
          |> Enum.map(fn {chunk, vector} ->
            %{
              repo_id: repo_id,
              file_path: chunk.file_path,
              chunk_index: chunk.index,
              content: chunk.content,
              embedding: vector,
              token_count: chunk.token_count,
              inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            }
          end)

        {count, _} = Repo.insert_all(Embedding, entries)
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Searches for the most similar embeddings to `query_vector` using pgvector cosine distance."
  @spec search(integer(), [float()], integer()) :: [Embedding.t()]
  def search(repo_id, query_vector, limit \\ 5) do
    Embedding
    |> where([e], e.repo_id == ^repo_id)
    |> order_by([e], fragment("embedding <=> ?", ^query_vector))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Asks a question about a repository using RAG.

  Embeds the question, retrieves similar code chunks via pgvector,
  and streams an LLM response grounded in the retrieved context.
  Supports conversation history via the `:history` option.
  """
  @spec ask(RepoRecord.t(), String.t(), keyword()) ::
          {:ok, String.t() | Enumerable.t()} | {:error, term()}
  def ask(%RepoRecord{} = repo, question, opts \\ []) do
    history = opts |> Keyword.get(:history, []) |> truncate_history()

    with {:ok, [query_vector]} <- Providers.embed(Config.embedding_provider(), [question]) do
      relevant_chunks = search(repo.id, query_vector, 5)

      context =
        relevant_chunks
        |> Enum.map(fn e -> "File: #{e.file_path}\n#{e.content}" end)
        |> Enum.join("\n\n---\n\n")

      # Build messages: system prompt + history + current question
      messages =
        [
          %{
            role: :system,
            content: """
            You are a helpful assistant that answers questions about code repositories.
            Use the following code context to answer the user's question.
            If the answer isn't in the context, say so.

            Context:
            #{context}
            """
          }
        ] ++ history ++ [%{role: :user, content: question}]

      Providers.chat(Config.chat_provider(), Config.chat_model(), messages, [
        {:cd, repo.local_path} | opts
      ])
    end
  end

  defp truncate_history(history) do
    # Process from newest to oldest, accumulating until we hit the limit
    history
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, total_chars} ->
      msg_chars = String.length(msg.content)
      new_total = total_chars + msg_chars

      if new_total <= @max_history_chars do
        {:cont, {[msg | acc], new_total}}
      else
        {:halt, {acc, total_chars}}
      end
    end)
    |> elem(0)
  end
end
