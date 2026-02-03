# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pearl is a Phoenix/Elixir web application that generates comprehensive wikis from code repositories using LLM integration. It combines git repository analysis, RAG (Retrieval-Augmented Generation) for Q&A, and wiki generation via AI models.

## Development Commands

All commands run from the `pearl/` directory:

```bash
# Setup (install deps, create DB, setup assets)
mix setup

# Start development server (localhost:4000)
mix phx.server

# Run all tests
mix test

# Run single test file
mix test test/pearl/wiki/generator_test.exs

# Run specific test by line
mix test test/pearl/wiki/generator_test.exs:42

# Exclude external API tests
mix test --exclude external

# Format code
mix format

# Pre-commit checks (compile with warnings-as-errors, format, test)
mix precommit

# Database operations
mix ecto.migrate
mix ecto.reset          # Drop and recreate
```

## Architecture

### Core Contexts (lib/pearl/)

- **`providers/`** - LLM provider abstraction layer
  - `provider.ex` - Behavior defining provider interface
  - `ollama.ex` - Local Ollama integration
  - `openrouter.ex` - OpenRouter cloud API
  - `claude_code.ex` - Claude Code CLI integration via claude_agent_sdk
  - `openai.ex` - OpenAI embeddings for specialized vector operations
  - `providers.ex` - Router facade selecting active provider
  - Note: Chat and embedding providers are decoupled for flexibility

- **`repositories/`** - Git repository management
  - `repositories.ex` - Context API for cloning/managing repos
  - `repo_record.ex` - Ecto schema for repo metadata
  - `git.ex` - Git CLI operations

- **`wiki/`** - Wiki generation pipeline
  - `wiki.ex` - Context API
  - `generator.ex` - Orchestrates multi-page wiki generation via LLM
  - `prompts.ex` - LLM prompt templates
  - `wiki_cache.ex` - Schema for caching generated wikis

- **`rag/`** - Retrieval-Augmented Generation
  - `rag.ex` - Context API for embedding/querying
  - `chunker.ex` - Code file chunking logic
  - `embedding.ex` - Schema with pgvector for similarity search

### Web Layer (lib/pearl_web/)

- **`live/home_live.ex`** - Repository list, clone form, wiki generation triggers
- **`live/wiki_live.ex`** - Wiki viewer with RAG-powered Q&A chat panel
- **`router.ex`** - Routes: `/` (home), `/wiki/:id` (wiki view)

### Key Data Flow

1. **Clone & Index**: `HomeLive` → `Repositories.clone()` → `Rag.index_repo()` (chunks + embeddings)
2. **Generate Wiki**: `Wiki.generate()` → analyze structure → score files → generate pages → cache
3. **RAG Q&A**: `WikiLive.ask()` → embed question → pgvector similarity search → stream response

## Database

PostgreSQL with pgvector extension required. Tables:
- `repos` - Repository metadata and status
- `wiki_caches` - Generated wiki content (structure + pages maps)
- `embeddings` - Vector embeddings with HNSW index for similarity search

## Environment Variables

```bash
# LLM Provider (ollama, openrouter, or claude-code)
LLM_PROVIDER=claude-code
LLM_MODEL=claude-sonnet-4-5-20250929

# Embedding Provider (ollama, openrouter, or openai)
# Decoupled from LLM_PROVIDER for specialized vector operations
EMBEDDING_PROVIDER=openai
EMBEDDING_MODEL=text-embedding-3-small

# Anthropic (for Claude Code CLI integration)
ANTHROPIC_API_KEY=sk-ant-...

# OpenAI (for embeddings)
OPENAI_API_KEY=sk-proj-...

# OpenRouter (alternative cloud provider)
OPENROUTER_API_KEY=sk-or-...

# Ollama (if using local)
OLLAMA_HOST=http://localhost:11434
OLLAMA_DEFAULT_MODEL=llama3.2:3b

# Storage
PEARL_REPOS_PATH=~/.pearl/repos
```

## Tech Stack

- **Backend**: Elixir 1.15+, Phoenix 1.8, Ecto with PostgreSQL
- **Frontend**: Phoenix LiveView 1.1, Tailwind CSS 4, daisyUI (retro/synthwave themes)
- **LLM**: Claude Code CLI (via claude_agent_sdk), Ollama (local), or OpenRouter (cloud)
- **Embeddings**: OpenAI text-embedding-3-small for specialized vector operations
- **Vector Search**: pgvector with HNSW indexing
