# Claude Code CLI + OpenAI Embeddings Integration

**Date:** 2026-02-03
**Status:** Design Complete
**Goal:** Enable local-only operation using Claude Code CLI for wiki generation and Q&A, with direct OpenAI API integration for embeddings

## Overview

Pearl currently supports Ollama (local) and OpenRouter (cloud) as LLM providers. This design adds:
1. **Claude Code CLI provider** - For chat/wiki generation using the `claude_agent_sdk` Hex package
2. **OpenAI provider** - For embeddings using a minimal Tesla+Mint wrapper
3. **Provider decoupling** - Separate configuration for chat vs embeddings providers

This enables cost-effective local development: Claude Code CLI for high-quality chat/wiki generation, OpenAI API for specialized embeddings.

## 1. Configuration Architecture

### Environment Variables

```bash
# Chat provider
LLM_PROVIDER=claude-code          # Options: ollama | openrouter | claude-code
LLM_MODEL=opus                    # Pass-through to Anthropic (opus | sonnet | haiku | full model ID)

# Embedding provider (optional, defaults to LLM_PROVIDER)
EMBEDDING_PROVIDER=openai         # Options: ollama | openrouter | openai
EMBEDDING_MODEL=text-embedding-3-large

# Provider-specific credentials
ANTHROPIC_API_KEY=sk-ant-...      # For claude-code provider
OPENAI_API_KEY=sk-...             # For openai embedding provider
OPENROUTER_API_KEY=sk-or-...      # For openrouter
```

### Config Module Updates

Update `lib/pearl/config.ex`:

```elixir
defmodule Pearl.Config do
  @moduledoc """
  Centralized configuration for Pearl LLM settings.
  """

  @spec provider() :: :ollama | :openrouter | :claude_code
  def provider do
    Application.get_env(:pearl, :llm_provider, :openrouter)
  end

  @spec model() :: String.t()
  def model do
    Application.get_env(:pearl, :llm_model, "opus")
  end

  @spec embedding_provider() :: :ollama | :openrouter | :openai
  def embedding_provider do
    # Fallback to chat provider if not explicitly set
    Application.get_env(:pearl, :embedding_provider) || provider()
  end

  @spec embedding_model() :: String.t()
  def embedding_model do
    Application.get_env(:pearl, :embedding_model, "text-embedding-3-small")
  end
end
```

### Runtime Configuration

Update `config/runtime.exs`:

```elixir
# LLM configuration from environment
llm_provider =
  case System.get_env("LLM_PROVIDER", "openrouter") do
    "ollama" -> :ollama
    "openrouter" -> :openrouter
    "claude-code" -> :claude_code
    _ -> :openrouter
  end

embedding_provider =
  case System.get_env("EMBEDDING_PROVIDER") do
    "ollama" -> :ollama
    "openrouter" -> :openrouter
    "openai" -> :openai
    nil -> llm_provider  # Fallback to LLM provider
    _ -> llm_provider
  end

config :pearl,
  llm_provider: llm_provider,
  llm_model: System.get_env("LLM_MODEL", "opus"),
  embedding_provider: embedding_provider,
  embedding_model: System.get_env("EMBEDDING_MODEL", "text-embedding-3-small")
```

### Backward Compatibility

- If `EMBEDDING_PROVIDER` is not set, defaults to `LLM_PROVIDER`
- Existing configurations work unchanged
- No breaking changes

## 2. Provider Architecture

### Current Structure

```
Pearl.Providers (facade)
├── chat(provider, model, messages, opts)
├── embed(provider, texts)
└── Routes to:
    ├── Pearl.Providers.Ollama
    └── Pearl.Providers.OpenRouter
```

### New Structure

```
Pearl.Providers (facade)
├── chat(provider, model, messages, opts)
│   ├── :ollama → Ollama.chat()
│   ├── :openrouter → OpenRouter.chat()
│   └── :claude_code → ClaudeCode.chat()  # New
│
└── embed(provider, texts)
    ├── :ollama → Ollama.embed()
    ├── :openrouter → OpenRouter.embed()
    └── :openai → OpenAI.embed()  # New
```

### Key Design Decision

**Chat provider and embedding provider are decoupled.** Wiki generation uses `Config.provider()` for chat, RAG indexing uses `Config.embedding_provider()` for embeddings.

### New Provider Modules

Both implement the `Pearl.Providers.Provider` behavior:

```elixir
@callback chat(model :: String.t(), messages :: [message()], opts :: chat_opts()) :: chat_result()
@callback embed(texts :: [String.t()]) :: embed_result()
```

## 3. Claude Agent SDK Integration

### SDK Overview

The `claude_agent_sdk` package (v0.9.2) provides Elixir integration with Claude Code CLI:
- **Published on Hex**: https://hex.pm/packages/claude_agent_sdk
- **Main API**: `ClaudeAgentSDK.query/2` returns a stream of messages
- **Authentication**: Uses `ANTHROPIC_API_KEY` env var automatically
- **Response format**: Stream of `ClaudeAgentSDK.Message` structs
- **Text extraction**: `ClaudeAgentSDK.ContentExtractor.extract_text/1`

### Implementation

**File:** `lib/pearl/providers/claude_code.ex`

```elixir
defmodule Pearl.Providers.ClaudeCode do
  @moduledoc """
  Provider implementation for Claude Code CLI using the claude_agent_sdk.
  Uses ClaudeAgentSDK.query/2 which returns a stream of messages.
  """

  @behaviour Pearl.Providers.Provider

  alias ClaudeAgentSDK.{Options, ContentExtractor, Message}

  require Logger

  @impl true
  def chat(model, messages, opts) do
    Logger.info("ClaudeCode: Starting chat request", model: model, stream: opts[:stream])

    stream? = Keyword.get(opts, :stream, false)

    # Build prompt from messages (convert OpenAI format to Claude format)
    prompt = format_messages_to_prompt(messages)

    # Configure SDK options
    sdk_options = %Options{
      model: normalize_model_name(model),
      output_format: :stream_json,
      max_turns: 1  # Single-turn for wiki generation
    }

    # Query returns a stream of ClaudeAgentSDK.Message structs
    message_stream = ClaudeAgentSDK.query(prompt, sdk_options)

    if stream? do
      # Return transformed stream for streaming responses
      transformed_stream =
        message_stream
        |> Stream.filter(&(&1.type == :assistant))
        |> Stream.map(&ContentExtractor.extract_text/1)
        |> Stream.reject(&(&1 == ""))

      Logger.debug("ClaudeCode: Chat streaming started")
      {:ok, transformed_stream}
    else
      # Collect all messages and extract final text
      case collect_response(message_stream) do
        {:ok, text} ->
          Logger.debug("ClaudeCode: Chat successful", response_length: byte_size(text))
          {:ok, text}

        {:error, reason} = error ->
          Logger.error("ClaudeCode: Chat failed",
            model: model,
            error: inspect(reason),
            messages_count: length(messages)
          )
          error
      end
    end
  end

  @impl true
  def embed(_texts) do
    # Claude doesn't provide embeddings
    {:error, :not_supported}
  end

  @impl true
  def list_models do
    # Return Claude models (SDK accepts short names)
    {:ok, [
      %{id: "opus", name: "Claude Opus 4.5"},
      %{id: "sonnet", name: "Claude Sonnet 4.5"},
      %{id: "haiku", name: "Claude Haiku 4.5"}
    ]}
  end

  @impl true
  def embedding_model, do: "not-supported"

  # Private helpers

  defp format_messages_to_prompt(messages) do
    # Convert OpenAI-style messages to a single prompt
    # Extract the last user message as the primary prompt
    messages
    |> Enum.filter(&(&1.role == "user"))
    |> List.last()
    |> Map.get(:content, "")
  end

  defp collect_response(message_stream) do
    try do
      text =
        message_stream
        |> Enum.filter(&(&1.type == :assistant))
        |> Enum.map(&ContentExtractor.extract_text/1)
        |> Enum.join("")

      if text == "" do
        {:error, :no_response}
      else
        {:ok, text}
      end
    rescue
      error ->
        {:error, error}
    end
  end

  defp normalize_model_name(model) do
    # SDK accepts: "opus", "sonnet", "haiku", or full model IDs
    case String.downcase(model) do
      "claude-opus-4-5" <> _ -> "opus"
      "claude-sonnet-4-5" <> _ -> "sonnet"
      "claude-haiku-4-5" <> _ -> "haiku"
      "opus" -> "opus"
      "sonnet" -> "sonnet"
      "haiku" -> "haiku"
      _ -> model  # Pass through full model IDs
    end
  end
end
```

### Key Decisions

- Use `claude_agent_sdk` v0.9.2 from Hex (https://hex.pm/packages/claude_agent_sdk)
- API key from `ANTHROPIC_API_KEY` env var (SDK handles automatically)
- SDK uses `ClaudeAgentSDK.query/2` which returns stream of `ClaudeAgentSDK.Message` structs
- Model names normalized to SDK format ("opus", "sonnet", "haiku")
- Text extraction via `ClaudeAgentSDK.ContentExtractor.extract_text/1`
- Streaming support: filter `:assistant` messages and extract text chunks
- Non-streaming: collect all messages and join text
- Embeddings return `{:error, :not_supported}`
- Single-turn mode (`max_turns: 1`) for wiki generation

## 4. OpenAI Embeddings Integration

Based on patterns from `/Users/ka/github/existential-birds/openai` library.

### Module Structure

**`lib/pearl/providers/openai/client.ex`** (~120 lines):

```elixir
defmodule Pearl.Providers.OpenAI.Client do
  @moduledoc """
  HTTP client for OpenAI API using Tesla + Mint.
  """

  @default_base_url "https://api.openai.com"
  @default_timeout 90_000

  def new(opts \\ []) do
    api_key = fetch_api_key!(opts)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    middleware = [
      {Tesla.Middleware.BaseUrl, base_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, [{"authorization", "Bearer #{api_key}"}]}
    ]

    adapter = {Tesla.Adapter.Mint, timeout: timeout, mode: :passive}
    Tesla.client(middleware, adapter)
  end

  def post(client, path, params, opts \\ []) do
    Tesla.post(client, path, params, opts)
  end

  def handle_response({:ok, %Tesla.Env{status: status, body: body}}, _opts) when status >= 400 do
    Logger.error("OpenAI API error",
      status: status,
      error: body["error"]["message"],
      type: body["error"]["type"],
      code: body["error"]["code"]
    )
    {:error, body}
  end

  def handle_response({:ok, %Tesla.Env{body: body}}, _opts) do
    {:ok, body}
  end

  def handle_response({:error, _reason} = error, _opts) do
    error
  end

  defp fetch_api_key!(opts) do
    case Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY") do
      nil ->
        Logger.error("Missing required environment variable", var: "OPENAI_API_KEY")
        raise "OPENAI_API_KEY not set"
      key ->
        Logger.debug("API key loaded from environment", var: "OPENAI_API_KEY")
        key
    end
  end
end
```

**`lib/pearl/providers/openai/embeddings.ex`** (~30 lines):

```elixir
defmodule Pearl.Providers.OpenAI.Embeddings do
  @moduledoc """
  OpenAI embeddings API wrapper.
  """

  alias Pearl.Providers.OpenAI.Client

  @type create_params :: %{
    required(:model) => String.t(),
    required(:input) => String.t() | [String.t()]
  }

  @spec create(Tesla.Client.t(), String.t() | [String.t()], String.t()) :: Client.result()
  def create(client, input, model) do
    params = %{model: model, input: input}

    client
    |> Client.post("/v1/embeddings", params)
    |> Client.handle_response([])
  end
end
```

**`lib/pearl/providers/openai.ex`** (Provider behavior implementation):

```elixir
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
```

### Dependencies

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:claude_agent_sdk, "~> 0.9.2"},  # Hex: https://hex.pm/packages/claude_agent_sdk
    {:tesla, "~> 1.6"},                # For OpenAI HTTP client
    {:mint, "~> 1.5"},                 # For OpenAI HTTP client
    # ... existing deps
  ]
end
```

## 5. Data Flow & Usage

### Wiki Generation Flow (Chat Provider)

```
HomeLive: User clicks "Generate Wiki"
    ↓
Wiki.generate(repo)
    ↓
Config.provider() → :claude_code
Config.model() → "opus"
    ↓
Generator.generate(repo, :claude_code, "opus")
    ↓
Providers.chat(:claude_code, "opus", messages, stream: false)
    ↓
ClaudeCode.chat() → ClaudeAgentSDK.chat()
    ↓
Returns wiki structure + pages
```

### RAG Indexing Flow (Embedding Provider)

```
HomeLive: After clone completes
    ↓
Rag.index_repo(repo)
    ↓
Config.embedding_provider() → :openai
Config.embedding_model() → "text-embedding-3-large"
    ↓
Chunker.chunk_file() → chunks
    ↓
Providers.embed(:openai, texts)
    ↓
OpenAI.embed() → Tesla → OpenAI API
    ↓
Vectors stored in pgvector
```

### RAG Query Flow (Both Providers)

```
WikiLive: User asks question
    ↓
Rag.ask(repo, question)
    ↓
1. Embed question: Providers.embed(:openai, [question])
2. Search vectors: pgvector similarity search
3. Answer question: Providers.chat(:claude_code, "opus", messages, stream: true)
    ↓
Stream response to user
```

### Benefits

- **Wiki generation:** Claude Opus via local SDK (high quality, cheaper than OpenRouter)
- **Embeddings:** OpenAI directly (specialized, cost-effective)
- **Q&A:** Claude for answers, OpenAI for query embedding
- **Local development:** No cloud costs for chat operations

## 6. Error Handling & Logging Strategy

### Logging Principles

1. **Provider-level logging** - Log request start, success, failure
2. **Client-level logging** - Log API errors with details
3. **Configuration logging** - Log key loading (not values)
4. **Context-aware logging** - Include relevant metadata

### Security Rules

- ❌ **NEVER log any part of API keys** (not even one character)
- ✅ Log only that the key was loaded/missing
- ❌ Never log request/response bodies containing sensitive data
- ✅ Log structured metadata (keyword lists)

### Logging Examples

**Provider-level (ClaudeCode, OpenAI):**

```elixir
Logger.info("ClaudeCode: Starting chat request", model: model, stream: opts[:stream])
Logger.debug("ClaudeCode: Chat successful", response_length: byte_size(response))
Logger.error("ClaudeCode: Chat failed",
  model: model,
  error: inspect(reason),
  messages_count: length(messages)
)
```

**Client-level (OpenAI.Client):**

```elixir
Logger.error("OpenAI API error",
  status: status,
  error: body["error"]["message"],
  type: body["error"]["type"],
  code: body["error"]["code"]
)
```

**Configuration validation:**

```elixir
Logger.error("Missing required environment variable", var: env_var)
Logger.debug("API key loaded from environment", var: env_var)
```

**Context-aware (RAG operations):**

```elixir
Logger.info("Starting repo indexing",
  repo_id: repo.id,
  repo_name: repo.name,
  embedding_provider: Config.embedding_provider(),
  embedding_model: Config.embedding_model()
)

Logger.error("Batch indexing failed",
  repo_id: repo.id,
  batch_size: length(batch),
  error: inspect(reason)
)
```

## 7. Testing & Migration Strategy

### Testing Approach

**1. Unit tests for new providers:**

```elixir
# test/pearl/providers/claude_code_test.exs
defmodule Pearl.Providers.ClaudeCodeTest do
  use ExUnit.Case

  test "chat/3 returns formatted response" do
    # Mock claude_agent_sdk responses
  end

  test "chat/3 handles streaming" do
    # Test stream enumerable
  end

  test "embed/1 returns not_supported error" do
    assert {:error, :not_supported} = ClaudeCode.embed(["test"])
  end
end

# test/pearl/providers/openai_test.exs
defmodule Pearl.Providers.OpenAITest do
  use ExUnit.Case

  setup do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"
    client = OpenAI.Client.new(base_url: url, api_key: "test-key")
    {:ok, bypass: bypass, client: client}
  end

  test "embed/1 returns vectors", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{
        "data" => [%{"embedding" => [0.1, 0.2, 0.3]}]
      }))
    end)

    assert {:ok, [[0.1, 0.2, 0.3]]} = OpenAI.embed(["test"])
  end
end
```

**2. Integration tests:**

```elixir
# test/pearl/rag/rag_test.exs
@tag :integration
test "index_repo uses configured embedding provider" do
  System.put_env("EMBEDDING_PROVIDER", "openai")
  # Test actual embedding flow
end

# test/pearl/wiki/generator_test.exs
@tag :integration
test "generate uses configured chat provider" do
  System.put_env("LLM_PROVIDER", "claude_code")
  # Test actual wiki generation
end
```

**3. Configuration tests:**

```elixir
# test/pearl/config_test.exs
test "embedding_provider falls back to llm_provider" do
  Application.put_env(:pearl, :llm_provider, :openrouter)
  Application.delete_env(:pearl, :embedding_provider)

  assert :openrouter == Config.embedding_provider()
end

test "embedding_provider can be set independently" do
  Application.put_env(:pearl, :llm_provider, :claude_code)
  Application.put_env(:pearl, :embedding_provider, :openai)

  assert :claude_code == Config.provider()
  assert :openai == Config.embedding_provider()
end
```

### Migration Steps

1. **Add dependencies to `mix.exs`:**
   - `{:claude_agent_sdk, "~> 0.9.2"}` (published on Hex)
   - `{:tesla, "~> 1.6"}`
   - `{:mint, "~> 1.5"}`

2. **Update `config/runtime.exs`** with new provider configuration

3. **Update `Pearl.Providers` facade** to route to new providers

4. **Add provider modules:**
   - `lib/pearl/providers/claude_code.ex`
   - `lib/pearl/providers/openai.ex`
   - `lib/pearl/providers/openai/client.ex`
   - `lib/pearl/providers/openai/embeddings.ex`

5. **Add tests** for all new modules

6. **Update documentation:**
   - `.env.example` with new env vars
   - `README.md` with usage examples
   - `CLAUDE.md` with new provider info

### Backward Compatibility

- ✅ Existing configs work without changes
- ✅ New env vars are optional (sensible defaults)
- ✅ No breaking changes to existing code
- ✅ `EMBEDDING_PROVIDER` defaults to `LLM_PROVIDER`

## Implementation Checklist

- [ ] Add dependencies to `mix.exs`
- [ ] Update `Pearl.Config` module
- [ ] Update `config/runtime.exs`
- [ ] Implement `Pearl.Providers.ClaudeCode`
- [ ] Implement `Pearl.Providers.OpenAI.Client`
- [ ] Implement `Pearl.Providers.OpenAI.Embeddings`
- [ ] Implement `Pearl.Providers.OpenAI`
- [ ] Update `Pearl.Providers` facade routing
- [ ] Add unit tests for ClaudeCode provider
- [ ] Add unit tests for OpenAI provider
- [ ] Add integration tests for RAG flow
- [ ] Add integration tests for wiki generation
- [ ] Add configuration tests
- [ ] Update `.env.example`
- [ ] Update `README.md`
- [ ] Update `CLAUDE.md`
- [ ] Run full test suite
- [ ] Manual testing with real APIs

## Success Criteria

- [ ] Can generate wikis using Claude Code CLI (local)
- [ ] Can create embeddings using OpenAI API (direct)
- [ ] Can run Q&A using both providers (OpenAI embeddings + Claude chat)
- [ ] All tests pass
- [ ] No API keys logged
- [ ] Comprehensive error messages for debugging
- [ ] Backward compatible with existing configs
- [ ] Documentation updated
