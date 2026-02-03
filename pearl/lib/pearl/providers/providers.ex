defmodule Pearl.Providers do
  @moduledoc """
  Facade for LLM provider interactions.
  Routes calls to appropriate provider client.
  """

  alias Pearl.Providers.{ClaudeCode, Ollama, OpenAI, OpenRouter}

  @type provider :: :ollama | :openrouter | :claude_code | :openai

  @spec chat(provider(), String.t(), [map()], keyword()) ::
          {:ok, String.t() | Enumerable.t()} | {:error, term()}
  def chat(provider, model, messages, opts \\ [])

  def chat(:ollama, model, messages, opts) do
    Ollama.chat(model, messages, opts)
  end

  def chat(:openrouter, model, messages, opts) do
    OpenRouter.chat(model, messages, opts)
  end

  def chat(:claude_code, model, messages, opts) do
    ClaudeCode.chat(model, messages, opts)
  end

  def chat(_provider, _model, _messages, _opts) do
    {:error, :unknown_provider}
  end

  @spec embed(provider(), [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed(provider, texts)

  def embed(:ollama, texts) do
    Ollama.embed(texts)
  end

  def embed(:openrouter, texts) do
    OpenRouter.embed(texts)
  end

  def embed(:openai, texts) do
    OpenAI.embed(texts)
  end

  def embed(_provider, _texts) do
    {:error, :unknown_provider}
  end

  @spec list_models(provider()) :: {:ok, [map()]} | {:error, term()}
  def list_models(provider)

  def list_models(:ollama) do
    Ollama.list_models()
  end

  def list_models(:openrouter) do
    OpenRouter.list_models()
  end

  def list_models(:claude_code) do
    ClaudeCode.list_models()
  end

  def list_models(:openai) do
    OpenAI.list_models()
  end

  def list_models(_provider) do
    {:error, :unknown_provider}
  end

  @spec embedding_model(provider()) :: String.t()
  def embedding_model(:ollama), do: Ollama.embedding_model()
  def embedding_model(:openrouter), do: OpenRouter.embedding_model()
  def embedding_model(:openai), do: OpenAI.embedding_model()
  def embedding_model(_provider), do: "unknown"
end
