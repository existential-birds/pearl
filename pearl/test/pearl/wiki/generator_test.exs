defmodule Pearl.Wiki.GeneratorTest do
  use ExUnit.Case, async: true

  alias Pearl.Wiki.Generator

  describe "parse_structure_response/1" do
    test "parses valid JSON response" do
      response = ~s({"pages": [{"id": "overview", "title": "Overview"}]})
      assert {:ok, %{"pages" => pages}} = Generator.parse_structure_response(response)
      assert length(pages) == 1
    end

    test "handles JSON with markdown code blocks" do
      response = """
      ```json
      {"pages": [{"id": "overview", "title": "Overview"}]}
      ```
      """

      assert {:ok, %{"pages" => _}} = Generator.parse_structure_response(response)
    end

    test "returns error for invalid JSON" do
      response = "not json"
      assert {:error, _} = Generator.parse_structure_response(response)
    end
  end

  describe "determine_page_type/1" do
    test "returns :overview for overview pages" do
      assert Generator.determine_page_type(%{"id" => "overview", "title" => "Overview"}) ==
               :overview

      assert Generator.determine_page_type(%{"id" => "project-overview", "title" => "Project"}) ==
               :overview
    end

    test "returns :getting_started for installation pages" do
      assert Generator.determine_page_type(%{
               "id" => "getting-started",
               "title" => "Getting Started"
             }) == :getting_started

      assert Generator.determine_page_type(%{"id" => "installation", "title" => "Installation"}) ==
               :getting_started

      assert Generator.determine_page_type(%{"id" => "quickstart", "title" => "Quickstart Guide"}) ==
               :getting_started

      assert Generator.determine_page_type(%{"id" => "setup", "title" => "Setup"}) ==
               :getting_started
    end

    test "returns :architecture for architecture pages" do
      assert Generator.determine_page_type(%{"id" => "architecture", "title" => "Architecture"}) ==
               :architecture

      assert Generator.determine_page_type(%{"id" => "design", "title" => "System Design"}) ==
               :architecture

      assert Generator.determine_page_type(%{"id" => "structure", "title" => "Project Structure"}) ==
               :architecture
    end

    test "returns :configuration for config pages" do
      assert Generator.determine_page_type(%{"id" => "configuration", "title" => "Configuration"}) ==
               :configuration

      assert Generator.determine_page_type(%{"id" => "config", "title" => "Config Options"}) ==
               :configuration

      assert Generator.determine_page_type(%{"id" => "settings", "title" => "Settings"}) ==
               :configuration
    end

    test "returns :default for other pages" do
      assert Generator.determine_page_type(%{"id" => "api", "title" => "API Reference"}) ==
               :default

      assert Generator.determine_page_type(%{
               "id" => "authentication",
               "title" => "Authentication"
             }) == :default
    end
  end

  describe "extract_keywords/1" do
    test "extracts keywords from page spec" do
      page_spec = %{
        "id" => "api-endpoints",
        "title" => "API Endpoints",
        "description" => "REST API documentation"
      }

      keywords = Generator.extract_keywords(page_spec)

      assert "api" in keywords
      assert "endpoints" in keywords
      assert "rest" in keywords
      assert "documentation" in keywords
    end

    test "filters short keywords" do
      page_spec = %{"id" => "a-bc", "title" => "A Test"}
      keywords = Generator.extract_keywords(page_spec)

      refute "a" in keywords
      refute "bc" in keywords
      assert "test" in keywords
    end

    test "handles missing fields" do
      page_spec = %{"id" => "test"}
      keywords = Generator.extract_keywords(page_spec)

      assert "test" in keywords
    end
  end

  describe "score_files/3" do
    test "scores README highly for overview pages" do
      files = ["README.md", "lib/app.ex", "src/main.py"]
      scores = Generator.score_files(files, :overview, [])

      readme_score = Enum.find(scores, fn {path, _} -> path == "README.md" end) |> elem(1)
      app_score = Enum.find(scores, fn {path, _} -> path == "lib/app.ex" end) |> elem(1)

      assert readme_score > app_score
    end

    test "scores package files highly for getting_started pages" do
      files = ["mix.exs", "lib/app.ex", "README.md"]
      scores = Generator.score_files(files, :getting_started, [])

      mix_score = Enum.find(scores, fn {path, _} -> path == "mix.exs" end) |> elem(1)
      app_score = Enum.find(scores, fn {path, _} -> path == "lib/app.ex" end) |> elem(1)

      assert mix_score > app_score
    end

    test "scores entry points highly for architecture pages" do
      files = ["lib/my_app/application.ex", "lib/my_app/router.ex", "lib/my_app/helpers.ex"]
      scores = Generator.score_files(files, :architecture, [])

      router_score =
        Enum.find(scores, fn {path, _} -> path == "lib/my_app/router.ex" end) |> elem(1)

      helpers_score =
        Enum.find(scores, fn {path, _} -> path == "lib/my_app/helpers.ex" end) |> elem(1)

      assert router_score > helpers_score
    end

    test "scores config files highly for configuration pages" do
      files = ["config/config.exs", "lib/app.ex", ".env.example"]
      scores = Generator.score_files(files, :configuration, [])

      config_score = Enum.find(scores, fn {path, _} -> path == "config/config.exs" end) |> elem(1)
      app_score = Enum.find(scores, fn {path, _} -> path == "lib/app.ex" end) |> elem(1)

      assert config_score > app_score
    end

    test "boosts files matching keywords" do
      files = ["lib/auth/token.ex", "lib/users/model.ex"]
      scores = Generator.score_files(files, :default, ["auth", "token"])

      auth_score = Enum.find(scores, fn {path, _} -> path == "lib/auth/token.ex" end) |> elem(1)
      users_score = Enum.find(scores, fn {path, _} -> path == "lib/users/model.ex" end) |> elem(1)

      assert auth_score > users_score
    end
  end

  describe "integration tests" do
    @tag :integration
    test "generate uses configured chat provider" do
      # Save original environment values
      original_llm_provider = System.get_env("LLM_PROVIDER")
      original_config = Application.get_env(:pearl, :llm_provider)

      try do
        # Set environment variable and update application config
        System.put_env("LLM_PROVIDER", "claude-code")
        Application.put_env(:pearl, :llm_provider, :claude_code)

        # Verify the config is set correctly
        assert Pearl.Config.provider() == :claude_code

        # Note: This test verifies that the provider configuration is set up correctly.
        # Actual wiki generation would require a valid API key and is intended to be
        # run manually or in a CI environment with proper credentials.
        # To fully test generation, you would call:
        # {:ok, wiki} = Pearl.Wiki.generate(repo_id, repo_path)
      after
        # Restore original environment
        if original_llm_provider do
          System.put_env("LLM_PROVIDER", original_llm_provider)
        else
          System.delete_env("LLM_PROVIDER")
        end

        if original_config do
          Application.put_env(:pearl, :llm_provider, original_config)
        else
          Application.delete_env(:pearl, :llm_provider)
        end
      end
    end

    @tag :integration
    test "generate with openai provider configuration" do
      # Save original environment values
      original_llm_provider = System.get_env("LLM_PROVIDER")
      original_config = Application.get_env(:pearl, :llm_provider)

      try do
        # Set environment variable and update application config
        System.put_env("LLM_PROVIDER", "openai")
        Application.put_env(:pearl, :llm_provider, :openai)

        # Verify the config is set correctly
        assert Pearl.Config.provider() == :openai

        # Note: This test verifies that the provider configuration is set up correctly.
        # Actual wiki generation would require a valid API key and is intended to be
        # run manually or in a CI environment with proper credentials.
      after
        # Restore original environment
        if original_llm_provider do
          System.put_env("LLM_PROVIDER", original_llm_provider)
        else
          System.delete_env("LLM_PROVIDER")
        end

        if original_config do
          Application.put_env(:pearl, :llm_provider, original_config)
        else
          Application.delete_env(:pearl, :llm_provider)
        end
      end
    end

    @tag :integration
    test "generate with openrouter provider configuration" do
      # Save original environment values
      original_llm_provider = System.get_env("LLM_PROVIDER")
      original_config = Application.get_env(:pearl, :llm_provider)

      try do
        # Set environment variable and update application config
        System.put_env("LLM_PROVIDER", "openrouter")
        Application.put_env(:pearl, :llm_provider, :openrouter)

        # Verify the config is set correctly
        assert Pearl.Config.provider() == :openrouter

        # Note: This test verifies that the provider configuration is set up correctly.
        # Actual wiki generation would require a valid API key and is intended to be
        # run manually or in a CI environment with proper credentials.
      after
        # Restore original environment
        if original_llm_provider do
          System.put_env("LLM_PROVIDER", original_llm_provider)
        else
          System.delete_env("LLM_PROVIDER")
        end

        if original_config do
          Application.put_env(:pearl, :llm_provider, original_config)
        else
          Application.delete_env(:pearl, :llm_provider)
        end
      end
    end
  end
end
