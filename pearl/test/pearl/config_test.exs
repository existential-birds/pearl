defmodule Pearl.ConfigTest do
  use ExUnit.Case, async: false

  alias Pearl.Config

  setup do
    # Store original configuration values
    original_llm_provider = Application.get_env(:pearl, :llm_provider)
    original_llm_model = Application.get_env(:pearl, :llm_model)
    original_embedding_provider = Application.get_env(:pearl, :embedding_provider)
    original_embedding_model = Application.get_env(:pearl, :embedding_model)

    # Teardown: restore original configuration
    on_exit(fn ->
      restore_config(:llm_provider, original_llm_provider)
      restore_config(:llm_model, original_llm_model)
      restore_config(:embedding_provider, original_embedding_provider)
      restore_config(:embedding_model, original_embedding_model)
    end)

    :ok
  end

  defp restore_config(_key, nil), do: :ok

  defp restore_config(key, value) do
    Application.put_env(:pearl, key, value)
  end

  describe "provider/0" do
    test "returns configured LLM provider" do
      Application.put_env(:pearl, :llm_provider, :ollama)
      assert :ollama == Config.provider()
    end

    test "returns :openrouter for openrouter provider" do
      Application.put_env(:pearl, :llm_provider, :openrouter)
      assert :openrouter == Config.provider()
    end

    test "returns :openai for openai provider" do
      Application.put_env(:pearl, :llm_provider, :openai)
      assert :openai == Config.provider()
    end

    test "defaults to :openrouter when not set" do
      Application.delete_env(:pearl, :llm_provider)
      assert :openrouter == Config.provider()
    end
  end

  describe "model/0" do
    test "returns configured chat model" do
      Application.put_env(:pearl, :llm_model, "openai/gpt-4o")
      assert "openai/gpt-4o" == Config.model()
    end

    test "returns custom model string" do
      Application.put_env(:pearl, :llm_model, "anthropic/claude-3-5-sonnet")
      assert "anthropic/claude-3-5-sonnet" == Config.model()
    end

    test "defaults to openai/gpt-5.2 when not set" do
      Application.delete_env(:pearl, :llm_model)
      assert "openai/gpt-5.2" == Config.model()
    end
  end

  describe "embedding_provider/0" do
    test "falls back to llm_provider when not set" do
      Application.put_env(:pearl, :llm_provider, :openrouter)
      Application.delete_env(:pearl, :embedding_provider)
      assert :openrouter == Config.embedding_provider()
    end

    test "falls back to ollama when llm_provider is ollama" do
      Application.put_env(:pearl, :llm_provider, :ollama)
      Application.delete_env(:pearl, :embedding_provider)
      assert :ollama == Config.embedding_provider()
    end

    test "can be set independently from llm_provider" do
      Application.put_env(:pearl, :llm_provider, :claude_code)
      Application.put_env(:pearl, :embedding_provider, :openai)
      assert :claude_code == Config.provider()
      assert :openai == Config.embedding_provider()
    end

    test "can use openai for embeddings with openrouter for chat" do
      Application.put_env(:pearl, :llm_provider, :openrouter)
      Application.put_env(:pearl, :embedding_provider, :openai)
      assert :openrouter == Config.provider()
      assert :openai == Config.embedding_provider()
    end

    test "can use openrouter for embeddings with ollama for chat" do
      Application.put_env(:pearl, :llm_provider, :ollama)
      Application.put_env(:pearl, :embedding_provider, :openrouter)
      assert :ollama == Config.provider()
      assert :openrouter == Config.embedding_provider()
    end

    test "returns explicit value when both are set" do
      Application.put_env(:pearl, :llm_provider, :ollama)
      Application.put_env(:pearl, :embedding_provider, :openai)
      assert :openai == Config.embedding_provider()
    end
  end

  describe "embedding_model/0" do
    test "returns configured embedding model" do
      Application.put_env(:pearl, :embedding_model, "openai/text-embedding-3-large")
      assert "openai/text-embedding-3-large" == Config.embedding_model()
    end

    test "returns custom embedding model string" do
      Application.put_env(:pearl, :embedding_model, "custom/embedding-model")
      assert "custom/embedding-model" == Config.embedding_model()
    end

    test "defaults to text-embedding-3-small when not set" do
      Application.delete_env(:pearl, :embedding_model)
      assert "text-embedding-3-small" == Config.embedding_model()
    end
  end

  describe "independent configuration" do
    test "chat and embedding can use different providers and models" do
      # Set up independent configuration
      Application.put_env(:pearl, :llm_provider, :claude_code)
      Application.put_env(:pearl, :llm_model, "claude-sonnet-4-5")
      Application.put_env(:pearl, :embedding_provider, :openai)
      Application.put_env(:pearl, :embedding_model, "text-embedding-3-large")

      # Verify chat configuration
      assert :claude_code == Config.provider()
      assert "claude-sonnet-4-5" == Config.model()

      # Verify embedding configuration
      assert :openai == Config.embedding_provider()
      assert "text-embedding-3-large" == Config.embedding_model()
    end

    test "embedding falls back to chat provider when only chat is configured" do
      Application.put_env(:pearl, :llm_provider, :openrouter)
      Application.put_env(:pearl, :llm_model, "openai/gpt-4o-mini")
      Application.delete_env(:pearl, :embedding_provider)
      Application.delete_env(:pearl, :embedding_model)

      assert :openrouter == Config.provider()
      assert "openai/gpt-4o-mini" == Config.model()
      assert :openrouter == Config.embedding_provider()
      assert "text-embedding-3-small" == Config.embedding_model()
    end

    test "all defaults work when nothing is configured" do
      Application.delete_env(:pearl, :llm_provider)
      Application.delete_env(:pearl, :llm_model)
      Application.delete_env(:pearl, :embedding_provider)
      Application.delete_env(:pearl, :embedding_model)

      assert :openrouter == Config.provider()
      assert "openai/gpt-5.2" == Config.model()
      assert :openrouter == Config.embedding_provider()
      assert "text-embedding-3-small" == Config.embedding_model()
    end
  end
end
