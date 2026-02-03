defmodule Pearl.Providers.OpenAI do
  @moduledoc """
  Provider implementation for OpenAI API (embeddings only).
  """

  @behaviour Pearl.Providers.Provider

  alias Pearl.Providers.OpenAI.{Client, Embeddings}

  require Logger

  @impl true
  def chat(_model, _messages, _opts) do
    {:error, :not_supported}
  end

  @impl true
  def embed(texts) do
    Logger.info("OpenAI: Starting embedding request", texts_count: length(texts))

    model = Pearl.Config.embedding_model()
    client = Client.new()

    case Embeddings.create(client, texts, model) do
      {:ok, %{"data" => data}} ->
        vectors = Enum.map(data, & &1["embedding"])
        Logger.debug("OpenAI: Embedding successful", vectors_count: length(vectors))
        {:ok, vectors}

      {:error, reason} = error ->
        Logger.error("OpenAI: Embedding failed",
          texts_count: length(texts),
          model: model,
          error: inspect(reason)
        )
        error
    end
  end

  @impl true
  def list_models do
    {:ok, [
      %{id: "text-embedding-3-large", name: "Text Embedding 3 Large"},
      %{id: "text-embedding-3-small", name: "Text Embedding 3 Small"}
    ]}
  end

  @impl true
  def embedding_model do
    Pearl.Config.embedding_model()
  end
end
