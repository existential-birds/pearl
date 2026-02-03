defmodule Pearl.Config do
  @moduledoc """
  Centralized configuration for Pearl LLM settings.

  This module provides access to LLM provider and model configuration
  via environment variables, ensuring consistent model usage across
  the application and preventing RAG mismatches that can occur when
  provider/model are selected dynamically via UI.

  Configuration is read from application environment:
  - `:llm_provider` - The LLM provider (`:ollama`, `:openrouter`, or `:openai`)
  - `:llm_model` - The chat model identifier string
  - `:embedding_provider` - The embedding provider (falls back to `:llm_provider` if not set)
  - `:embedding_model` - The embedding model identifier string
  """

  @doc """
  Returns the configured LLM provider.

  Reads from `Application.get_env(:pearl, :llm_provider)`.

  ## Returns
  - `:ollama`, `:openrouter`, or `:openai` (default: `:openrouter`)
  """
  @spec provider() :: :ollama | :openrouter | :openai
  def provider do
    Application.get_env(:pearl, :llm_provider, :openrouter)
  end

  @doc """
  Returns the configured chat model.

  Reads from `Application.get_env(:pearl, :llm_model)`.

  ## Returns
  - Model identifier string (default: `"openai/gpt-5.2"`)
  """
  @spec model() :: String.t()
  def model do
    Application.get_env(:pearl, :llm_model, "openai/gpt-5.2")
  end

  @doc """
  Returns the configured embedding provider.

  Reads from `Application.get_env(:pearl, :embedding_provider)`.
  Falls back to the chat provider if not explicitly set.

  ## Returns
  - `:ollama`, `:openrouter`, or `:openai` (default: falls back to `provider()`)
  """
  @spec embedding_provider() :: :ollama | :openrouter | :openai
  def embedding_provider do
    Application.get_env(:pearl, :embedding_provider) || provider()
  end

  @doc """
  Returns the configured embedding model.

  Reads from `Application.get_env(:pearl, :embedding_model)`.

  ## Returns
  - Embedding model identifier string (default: `"text-embedding-3-small"`)
  """
  @spec embedding_model() :: String.t()
  def embedding_model do
    Application.get_env(:pearl, :embedding_model, "text-embedding-3-small")
  end
end
