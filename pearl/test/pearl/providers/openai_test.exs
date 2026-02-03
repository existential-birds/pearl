defmodule Pearl.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Pearl.Providers.OpenAI

  describe "chat/3" do
    test "returns not_supported error" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :not_supported} = OpenAI.chat("gpt-4", messages, [])
    end

    test "returns not_supported for any model" do
      messages = [%{role: "user", content: "Test"}]
      assert {:error, :not_supported} = OpenAI.chat("gpt-3.5-turbo", messages, stream: true)
    end

    test "returns not_supported with empty messages" do
      assert {:error, :not_supported} = OpenAI.chat("gpt-4", [], [])
    end
  end

  describe "embed/1" do
    @tag :external
    test "requires OPENAI_API_KEY to be set for real API calls" do
      # This test would make a real API call if OPENAI_API_KEY is set
      # It's tagged :external so it's skipped by default
      case System.get_env("OPENAI_API_KEY") do
        nil ->
          # API key not set, can't test real API
          :ok

        _key ->
          texts = ["Hello world"]
          assert {:ok, [embedding]} = OpenAI.embed(texts)
          assert is_list(embedding)
          assert length(embedding) > 0
          assert Enum.all?(embedding, &is_float/1)
      end
    end
  end

  describe "list_models/0" do
    test "returns list of OpenAI embedding models" do
      assert {:ok, models} = OpenAI.list_models()
      assert is_list(models)
      assert length(models) == 2

      assert Enum.any?(models, fn model -> model.id == "text-embedding-3-large" end)
      assert Enum.any?(models, fn model -> model.id == "text-embedding-3-small" end)

      Enum.each(models, fn model ->
        assert Map.has_key?(model, :id)
        assert Map.has_key?(model, :name)
        assert is_binary(model.id)
        assert is_binary(model.name)
      end)
    end

    test "returns models with correct structure" do
      assert {:ok, [model1, model2]} = OpenAI.list_models()

      # Check first model
      assert model1.id == "text-embedding-3-large"
      assert model1.name == "Text Embedding 3 Large"

      # Check second model
      assert model2.id == "text-embedding-3-small"
      assert model2.name == "Text Embedding 3 Small"
    end
  end

  describe "embedding_model/0" do
    test "returns configured embedding model" do
      original = Application.get_env(:pearl, :embedding_model)
      Application.put_env(:pearl, :embedding_model, "text-embedding-3-large")

      assert OpenAI.embedding_model() == "text-embedding-3-large"

      # Restore original value
      if original do
        Application.put_env(:pearl, :embedding_model, original)
      else
        Application.delete_env(:pearl, :embedding_model)
      end
    end

    test "returns default embedding model when not configured" do
      original = Application.get_env(:pearl, :embedding_model)
      Application.delete_env(:pearl, :embedding_model)

      assert OpenAI.embedding_model() == "text-embedding-3-small"

      # Restore original value
      if original do
        Application.put_env(:pearl, :embedding_model, original)
      end
    end

    test "uses Pearl.Config for embedding model" do
      # This test verifies that embedding_model/0 delegates to Pearl.Config
      original = Application.get_env(:pearl, :embedding_model)

      Application.put_env(:pearl, :embedding_model, "custom-model")
      assert OpenAI.embedding_model() == Pearl.Config.embedding_model()
      assert OpenAI.embedding_model() == "custom-model"

      # Restore original value
      if original do
        Application.put_env(:pearl, :embedding_model, original)
      else
        Application.delete_env(:pearl, :embedding_model)
      end
    end
  end
end
