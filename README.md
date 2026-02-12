# Pearl

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/existential-birds/pearl)

<img width="1421" height="989" alt="pearl_qa" src="https://github.com/user-attachments/assets/d3a7730c-f1d2-43f6-8908-e38fd6d3db65" />

Pearl is a RAG (Retrieval-Augmented Generation) system built with Elixir and Phoenix. It generates comprehensive wikis from code repositories, allowing you to ask questions about any codebase using natural language.

This project was inspired by [DeepWiki from Devin](https://cognition.ai/blog/deepwiki) and created as a learning exercise to explore Elixir, Phoenix LiveView, and RAG architectures—starting with naive RAG and progressing through techniques from recent research papers.

_Named after [Pearl I. Young](https://en.wikipedia.org/wiki/Pearl_I._Young) (1895–1968), the first female technical employee of NACA (which became NASA) and the second female physicist in the U.S. federal government. After earning degrees in physics, chemistry, and mathematics from the University of North Dakota in 1919, she joined NACA's Langley Laboratory in 1922 as a physicist calibrating flight instrumentation. In 1929, she became Langley's Chief Technical Editor and established the NACA technical reports system, authoring the *Style Manual for Engineering Authors* that shaped how government aerospace engineers communicated for decades. NASA's History Office called her "the architect of the NACA technical reports system." In 2015, she was inducted into NASA Langley's Hall of Honor._

## What Does Pearl Do?

1. **Clone any Git repository** — Point Pearl at a GitHub URL and it fetches the code
2. **Generate a wiki** — An LLM analyzes the codebase and creates structured documentation
3. **Ask questions** — Use the built-in chat to ask questions about the code; Pearl finds relevant code snippets and explains them

## Quick Start (Docker)

Run Pearl without installing Elixir, Hex, or Node.js:

```bash
git clone https://github.com/existential-birds/pearl.git
cd pearl
docker compose up
```

Pearl will be available at [http://localhost:4000](http://localhost:4000).

### LLM Provider Configuration

Set your LLM provider via environment variables or a `.env` file:

```bash
# OpenRouter (default)
export OPENROUTER_API_KEY=sk-or-...
docker compose up

# Ollama (local)
export LLM_PROVIDER=ollama
export OLLAMA_HOST=http://host.docker.internal:11434
docker compose up
```

### Using a `.env` file

Create a `.env` file in the project root:

```env
OPENROUTER_API_KEY=sk-or-...
LLM_PROVIDER=openrouter
LLM_MODEL=openai/gpt-5.2
SECRET_KEY_BASE=generate-with-mix-phx-gen-secret
```

### Data Persistence

- **Database**: Stored in `pearl_pgdata` Docker volume
- **Cloned repos**: Stored in `pearl_repos` Docker volume

## Prerequisites (Development Setup)

To develop Pearl locally, you'll need to install:

### 1. Elixir and Erlang

Elixir is the programming language Pearl is written in. The easiest way to install it:

#### macOS (using Homebrew)

```bash
brew install elixir
```

#### Other platforms

Follow the official [Elixir installation guide](https://elixir-lang.org/install.html).

Verify the installation:

```bash
elixir --version
# Should show Elixir 1.15 or higher
```

### 2. PostgreSQL with pgvector

Pearl uses PostgreSQL to store repository data and vector embeddings for search. The easiest way is Docker (recommended):

```bash
docker compose up -d
```

This starts PostgreSQL 18 with pgvector pre-installed. Data persists across restarts via a named volume.

**Port conflict?** If port 5432 is already in use:

```bash
export PEARL_DB_PORT=5433
docker compose up -d
```

<details>
<summary>Alternative: Native install</summary>

#### macOS (using Homebrew)

```bash
brew install postgresql@16 pgvector
brew services start postgresql@16
```

#### Other platforms

See the [PostgreSQL download page](https://www.postgresql.org/download/) and [pgvector installation instructions](https://github.com/pgvector/pgvector#installation).

</details>

### 3. LLM Provider

Pearl needs an LLM to generate wikis and answer questions. Choose one:

#### Option A: OpenRouter (Recommended for beginners)

1. Create an account at [openrouter.ai](https://openrouter.ai/)
2. Generate an API key
3. Set the environment variable:

   ```bash
   export OPENROUTER_API_KEY=sk-your-key-here
   ```

#### Option B: Ollama (Run models locally)

1. Install from [ollama.ai](https://ollama.ai/)
2. Pull a model:

   ```bash
   ollama pull llama3.2:3b
   ```

## Setup

1. **Clone this repository:**

   ```bash
   git clone https://github.com/existential-birds/pearl.git
   cd pearl/pearl
   ```

2. **Start PostgreSQL** (if using Docker):

   ```bash
   docker compose up -d
   ```

3. **Configure your LLM provider** by setting environment variables (either export directly in your terminal or add to a `.env` file to source later):

   ```bash
   # For OpenRouter (recommended)
   export LLM_PROVIDER=openrouter
   export LLM_MODEL=openai/gpt-5.2
   export EMBEDDING_MODEL=openai/text-embedding-3-small
   export OPENROUTER_API_KEY=sk-your-key-here

   # For Ollama (local)
   # export LLM_PROVIDER=ollama
   # export OLLAMA_HOST=http://localhost:11434
   # export OLLAMA_DEFAULT_MODEL=llama3.2:3b
   ```

4. **Run setup:**

   ```bash
   mix setup
   ```

5. **Start the server:**

   ```bash
   mix phx.server
   ```

6. **Open Pearl** in your browser at [http://localhost:4000](http://localhost:4000)

## Usage

1. On the home page, paste a GitHub repository URL and click "Clone"
2. Once cloned, click "Generate Wiki" to create documentation
3. Browse the generated wiki pages
4. Use the chat panel to ask questions about the codebase

## Architecture

Pearl combines several components:

- **Phoenix LiveView** — Real-time web interface with no JavaScript required
- **RAG Pipeline** — Chunks code files, generates embeddings, and searches for relevant context
- **LLM Integration** — Supports both cloud (OpenRouter) and local (Ollama) providers
- **pgvector** — Stores and searches vector embeddings for similarity matching

For detailed architecture documentation, see [CLAUDE.md](./CLAUDE.md).

### RAG Implementation

One goal of Pearl is to explore different RAG (Retrieval-Augmented Generation) architectures. We start with the simplest approach and progressively implement more sophisticated techniques from research papers.

#### Current: Naive RAG

Pearl currently implements **Naive RAG**, the baseline architecture:

| Component | Implementation |
|-----------|----------------|
| **Chunking** | Fixed 500-token chunks with semantic break detection (paragraph boundaries preferred) |
| **Embedding** | OpenAI `text-embedding-3-small` (1536 dimensions) via OpenRouter, or `nomic-embed-text` via Ollama |
| **Vector Store** | PostgreSQL with pgvector extension, HNSW indexing |
| **Retrieval** | Top-5 chunks by cosine similarity |
| **Generation** | Retrieved chunks concatenated into system prompt with chat history |

This approach is simple and works well for small-to-medium codebases, but has known limitations: no chunk overlap means context can be lost at boundaries, fixed-size chunking ignores code semantics, and top-k retrieval may miss relevant but dissimilar chunks.

#### Roadmap: Advanced RAG Techniques

Future implementations will explore strategies from [ottomator-agents](https://github.com/coleam00/ottomator-agents/tree/main/all-rag-strategies), combining 3-5 techniques for optimal results:

- **Re-ranking** — Two-stage retrieval with cross-encoder scoring ([MS MARCO](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L6-v2))
- **Contextual Retrieval** — LLM adds context to chunks before embedding ([Anthropic](https://www.anthropic.com/news/contextual-retrieval))
- **Context-aware Chunking** — Split at semantic boundaries via [Docling](https://docling-project.github.io/docling/concepts/chunking/)
- **Late Chunking** — Embed full document, then chunk ([arXiv:2409.04701](https://arxiv.org/abs/2409.04701))
- **Query Expansion / Multi-Query** — Generate query variations for broader coverage
- **Hierarchical RAG** — Search child chunks, return parent context
- **Knowledge Graphs** — Vector search + graph traversal ([Graphiti](https://github.com/getzep/graphiti))
- **Agentic RAG** — Agent chooses retrieval method per query ([arXiv:2501.09136](https://arxiv.org/abs/2501.09136))
- **Self-Reflective RAG** — LLM grades and refines retrieval ([arXiv:2310.11511](https://arxiv.org/abs/2310.11511))
- **Fine-tuned Embeddings** — Domain-specific embedding models for 5-10% accuracy gain

## Development

```bash
# Run tests
mix test

# Format code
mix format

# Run pre-commit checks
mix precommit
```

## License

Apache 2.0
