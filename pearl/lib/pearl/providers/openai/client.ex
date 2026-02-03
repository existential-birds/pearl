defmodule Pearl.Providers.OpenAI.Client do
  @moduledoc """
  HTTP client for OpenAI API using Tesla + Mint.
  """

  require Logger

  @default_base_url "https://api.openai.com"
  @default_timeout 90_000

  @doc """
  Creates a new Tesla client configured for OpenAI API.

  ## Options

    * `:api_key` - OpenAI API key (defaults to OPENAI_API_KEY env var)
    * `:base_url` - Base URL for API (defaults to "https://api.openai.com")
    * `:timeout` - Request timeout in milliseconds (defaults to 90_000)

  ## Examples

      iex> client = Pearl.Providers.OpenAI.Client.new()
      %Tesla.Client{}

      iex> client = Pearl.Providers.OpenAI.Client.new(api_key: "sk-...")
      %Tesla.Client{}

  """
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

  @doc """
  Makes a POST request to the OpenAI API.

  ## Parameters

    * `client` - Tesla client created with `new/1`
    * `path` - API endpoint path (e.g., "/v1/embeddings")
    * `params` - Request body parameters (will be JSON encoded)
    * `opts` - Additional Tesla options (optional)

  ## Examples

      iex> client = Pearl.Providers.OpenAI.Client.new()
      iex> Pearl.Providers.OpenAI.Client.post(client, "/v1/embeddings", %{model: "text-embedding-3-small", input: "Hello"})
      {:ok, %Tesla.Env{}}

  """
  def post(client, path, params, opts \\ []) do
    Tesla.post(client, path, params, opts)
  end

  @doc """
  Handles HTTP response from OpenAI API.

  Returns `{:ok, body}` for successful responses (status < 400).
  Returns `{:error, body}` for error responses (status >= 400).
  Logs error details when status >= 400.

  ## Parameters

    * `response` - Tesla response tuple
    * `opts` - Additional options (currently unused)

  ## Examples

      iex> Pearl.Providers.OpenAI.Client.handle_response({:ok, %Tesla.Env{status: 200, body: %{}}}, [])
      {:ok, %{}}

      iex> Pearl.Providers.OpenAI.Client.handle_response({:ok, %Tesla.Env{status: 401, body: %{"error" => %{}}}}, [])
      {:error, %{"error" => %{}}}

  """
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

  @doc """
  Fetches the OpenAI API key from options or environment.

  Checks in order:
  1. `:api_key` option
  2. `OPENAI_API_KEY` environment variable

  Raises if no API key is found.

  ## Parameters

    * `opts` - Keyword list that may contain `:api_key`

  ## Examples

      iex> Pearl.Providers.OpenAI.Client.fetch_api_key!([api_key: "sk-..."])
      "sk-..."

  """
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
