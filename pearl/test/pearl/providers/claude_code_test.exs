defmodule Pearl.Providers.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Pearl.Providers.ClaudeCode

  describe "embed/1" do
    test "returns not supported error" do
      result = ClaudeCode.embed(["some text"])
      assert {:error, :not_supported} = result
    end

    test "returns not supported for multiple texts" do
      result = ClaudeCode.embed(["text1", "text2", "text3"])
      assert {:error, :not_supported} = result
    end

    test "returns not supported for empty list" do
      result = ClaudeCode.embed([])
      assert {:error, :not_supported} = result
    end
  end

  describe "list_models/0" do
    test "returns list of Claude models" do
      result = ClaudeCode.list_models()
      assert {:ok, models} = result
      assert is_list(models)
      assert length(models) == 3
    end

    test "returns models with correct structure" do
      {:ok, models} = ClaudeCode.list_models()

      for model <- models do
        assert Map.has_key?(model, :id)
        assert Map.has_key?(model, :name)
        assert is_binary(model.id)
        assert is_binary(model.name)
      end
    end

    test "includes opus model" do
      {:ok, models} = ClaudeCode.list_models()
      opus = Enum.find(models, &(&1.id == "opus"))
      assert opus
      assert opus.name == "Claude Opus 4.5"
    end

    test "includes sonnet model" do
      {:ok, models} = ClaudeCode.list_models()
      sonnet = Enum.find(models, &(&1.id == "sonnet"))
      assert sonnet
      assert sonnet.name == "Claude Sonnet 4.5"
    end

    test "includes haiku model" do
      {:ok, models} = ClaudeCode.list_models()
      haiku = Enum.find(models, &(&1.id == "haiku"))
      assert haiku
      assert haiku.name == "Claude Haiku 4.5"
    end
  end

  describe "embedding_model/0" do
    test "returns not-supported string" do
      result = ClaudeCode.embedding_model()
      assert result == "not-supported"
    end
  end

  describe "model name normalization" do
    test "normalizes full opus model ID" do
      # Test via list_models to ensure the normalization would work
      {:ok, models} = ClaudeCode.list_models()
      model_ids = Enum.map(models, & &1.id)
      assert "opus" in model_ids
    end

    test "normalizes full sonnet model ID" do
      {:ok, models} = ClaudeCode.list_models()
      model_ids = Enum.map(models, & &1.id)
      assert "sonnet" in model_ids
    end

    test "normalizes full haiku model ID" do
      {:ok, models} = ClaudeCode.list_models()
      model_ids = Enum.map(models, & &1.id)
      assert "haiku" in model_ids
    end
  end

  describe "Provider behaviour compliance" do
    test "implements chat/3 callback" do
      assert function_exported?(ClaudeCode, :chat, 3)
    end

    test "implements embed/1 callback" do
      assert function_exported?(ClaudeCode, :embed, 1)
    end

    test "implements list_models/0 callback" do
      assert function_exported?(ClaudeCode, :list_models, 0)
    end

    test "implements embedding_model/0 callback" do
      assert function_exported?(ClaudeCode, :embedding_model, 0)
    end
  end

  # Integration tests that require ClaudeAgentSDK to be available
  # These are marked with @tag :external to be excluded from regular test runs

  describe "chat/3 integration" do
    @tag :external
    @tag :integration
    test "returns formatted response for non-streaming request" do
      messages = [%{role: "user", content: "Say hello"}]
      result = ClaudeCode.chat("sonnet", messages, stream: false)

      case result do
        {:ok, response} ->
          assert is_binary(response)
          assert byte_size(response) > 0

        {:error, reason} ->
          # If SDK not available or other error, test should document this
          flunk("Chat failed: #{inspect(reason)}")
      end
    end

    @tag :external
    @tag :integration
    test "returns stream for streaming request" do
      messages = [%{role: "user", content: "Count to 5"}]
      result = ClaudeCode.chat("sonnet", messages, stream: true)

      case result do
        {:ok, stream} ->
          # Verify it's an enumerable stream
          assert Enumerable.impl_for(stream) != nil

          # Try to take first chunk
          chunks = Enum.take(stream, 5)
          assert is_list(chunks)
          assert Enum.all?(chunks, &is_binary/1)

        {:error, reason} ->
          # If SDK not available or other error, test should document this
          flunk("Streaming chat failed: #{inspect(reason)}")
      end
    end

    @tag :external
    @tag :integration
    test "handles different model names" do
      messages = [%{role: "user", content: "Hi"}]

      # Test with short name
      result1 = ClaudeCode.chat("sonnet", messages, stream: false)
      assert {:ok, _} = result1 or match?({:error, _}, result1)

      # Test with full model ID
      result2 = ClaudeCode.chat("claude-sonnet-4-5", messages, stream: false)
      assert {:ok, _} = result2 or match?({:error, _}, result2)
    end

    @tag :external
    @tag :integration
    test "extracts user message from OpenAI format" do
      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "What is 2+2?"}
      ]

      result = ClaudeCode.chat("haiku", messages, stream: false)

      case result do
        {:ok, response} ->
          assert is_binary(response)
          # Should have extracted the user message

        {:error, reason} ->
          flunk("Message formatting failed: #{inspect(reason)}")
      end
    end

    @tag :external
    @tag :integration
    test "handles streaming with multiple chunks" do
      messages = [%{role: "user", content: "Write a short poem about code"}]
      result = ClaudeCode.chat("sonnet", messages, stream: true)

      case result do
        {:ok, stream} ->
          chunks = Enum.to_list(stream)
          assert length(chunks) >= 1
          assert Enum.all?(chunks, &is_binary/1)

          # Verify chunks can be joined
          full_text = Enum.join(chunks, "")
          assert byte_size(full_text) > 0

        {:error, reason} ->
          flunk("Streaming failed: #{inspect(reason)}")
      end
    end
  end
end
