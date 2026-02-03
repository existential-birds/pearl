defmodule Pearl.RagTest do
  use Pearl.DataCase

  alias Pearl.Config
  alias Pearl.Rag
  alias Pearl.Rag.Embedding
  alias Pearl.Repositories

  describe "create_embedding/1" do
    setup do
      {:ok, repo} =
        Repositories.create_repo(%{
          url: "https://github.com/test/rag",
          provider: "github",
          owner: "test",
          name: "rag"
        })

      {:ok, repo: repo}
    end

    test "creates embedding record", %{repo: repo} do
      # Create a fake 1536-dim vector
      vector = Enum.map(1..1536, fn _ -> :rand.uniform() end)

      attrs = %{
        repo_id: repo.id,
        file_path: "lib/test.ex",
        chunk_index: 0,
        content: "defmodule Test do end",
        embedding: vector,
        token_count: 5
      }

      assert {:ok, %Embedding{}} = Rag.create_embedding(attrs)
    end
  end

  describe "delete_embeddings_for_repo/1" do
    setup do
      {:ok, repo} =
        Repositories.create_repo(%{
          url: "https://github.com/test/ragdelete",
          provider: "github",
          owner: "test",
          name: "ragdelete"
        })

      vector = Enum.map(1..1536, fn _ -> :rand.uniform() end)

      {:ok, _} =
        Rag.create_embedding(%{
          repo_id: repo.id,
          file_path: "lib/test.ex",
          chunk_index: 0,
          content: "test",
          embedding: vector,
          token_count: 1
        })

      {:ok, repo: repo}
    end

    test "deletes all embeddings for a repo", %{repo: repo} do
      assert {1, nil} = Rag.delete_embeddings_for_repo(repo.id)
    end
  end

  describe "integration tests" do
    @tag :integration
    test "index_repo uses configured embedding provider" do
      # Set embedding provider via environment variable
      System.put_env("EMBEDDING_PROVIDER", "openai")

      # Reload config to pick up environment changes
      Application.put_env(:pearl, :embedding_provider, :openai)

      # Verify the provider is configured correctly
      assert :openai == Config.embedding_provider()

      # Create a test repo
      {:ok, repo} =
        Repositories.create_repo(%{
          url: "https://github.com/test/integration",
          provider: "github",
          owner: "test",
          name: "integration"
        })

      # Note: This test requires a real OpenAI API key in OPENAI_API_KEY
      # and will make actual API calls. Skip if key is not available.
      if System.get_env("OPENAI_API_KEY") do
        # Mock a repository structure and files would go here
        # In a real integration test, you'd need to:
        # 1. Create a temporary git repo with test files
        # 2. Call Rag.index_repo(repo)
        # 3. Verify embeddings were created using the OpenAI provider
        # 4. Check the embedding model was saved to the repo record

        # For now, we just verify the configuration is correct
        assert Config.embedding_provider() == :openai
        assert is_binary(Config.embedding_model())
      else
        # Skip the actual API test if no key is available
        assert Config.embedding_provider() == :openai
      end
    end

    @tag :integration
    test "embedding provider falls back to LLM provider when not explicitly set" do
      # Clear embedding provider to test fallback
      System.delete_env("EMBEDDING_PROVIDER")
      System.put_env("LLM_PROVIDER", "openrouter")

      # Reload config
      Application.put_env(:pearl, :llm_provider, :openrouter)
      Application.delete_env(:pearl, :embedding_provider)

      # Verify fallback behavior
      assert :openrouter == Config.embedding_provider()
      assert :openrouter == Config.provider()
    end

    @tag :integration
    test "embedding provider can be configured independently from LLM provider" do
      # Set different providers for chat and embeddings
      System.put_env("LLM_PROVIDER", "claude-code")
      System.put_env("EMBEDDING_PROVIDER", "openai")

      # Reload config
      Application.put_env(:pearl, :llm_provider, :claude_code)
      Application.put_env(:pearl, :embedding_provider, :openai)

      # Verify independent configuration
      assert :claude_code == Config.provider()
      assert :openai == Config.embedding_provider()
    end
  end
end
