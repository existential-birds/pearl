defmodule Pearl.Providers.OpenRouter do
  @moduledoc """
  OpenRouter LLM provider client.
  """

  @behaviour Pearl.Providers.Provider

  require Logger

  @base_url "https://openrouter.ai/api/v1"
  @embed_max_retries 3
  @embed_base_delay_ms 1_000

  @impl true
  def chat(model, messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        body = %{
          model: model,
          messages: messages,
          stream: Keyword.get(opts, :stream, false)
        }

        case Keyword.get(opts, :stream, false) do
          false -> chat_sync(body, key)
          true -> chat_stream(body, key)
        end
    end
  end

  defp chat_sync(body, key) do
    case Req.post("#{@base_url}/chat/completions",
           json: body,
           headers: headers(key)
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_stream(body, key) do
    case start_stream(body, key) do
      {:ok, resp} ->
        stream =
          Stream.resource(
            fn -> resp end,
            &next_chunk/1,
            &finish_stream/1
          )

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_stream(body, key) do
    case Req.post("#{@base_url}/chat/completions",
           json: body,
           headers: headers(key),
           into: :self,
           receive_timeout: 60_000
         ) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_chunk(%Req.Response{} = resp) do
    receive do
      {_ref, {:data, data}} ->
        case parse_sse_events(data) do
          :done -> {:halt, resp}
          chunks -> {chunks, resp}
        end

      {_ref, :done} ->
        {:halt, resp}

      _unexpected ->
        {[], resp}
    after
      30_000 -> {:halt, resp}
    end
  end

  defp parse_sse_events(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.reduce_while([], fn line, acc ->
      cond do
        line == "data: [DONE]" ->
          {:halt, :done}

        String.starts_with?(line, "data: ") ->
          json = String.trim_leading(line, "data: ")

          case Jason.decode(json) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}}
            when is_binary(content) ->
              {:cont, [content | acc]}

            _ ->
              {:cont, acc}
          end

        true ->
          {:cont, acc}
      end
    end)
    |> case do
      :done -> :done
      list when is_list(list) -> Enum.reverse(list)
    end
  end

  @impl true
  def embed(texts) do
    case api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        model = embedding_model()
        do_embed(texts, model, key, 0)
    end
  end

  defp do_embed(texts, model, key, attempt) do
    case Req.post("#{@base_url}/embeddings",
           json: %{model: model, input: texts},
           headers: headers(key)
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Enum.map(data, & &1["embedding"])}

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: 200, body: %{"error" => _} = resp_body}} ->
        maybe_retry_embed(texts, model, key, attempt, {:http_error, 200, resp_body})

      {:ok, %{status: status, body: resp_body}} when status in [429, 500, 502, 503, 504] ->
        maybe_retry_embed(texts, model, key, attempt, {:http_error, status, resp_body})

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        maybe_retry_embed(texts, model, key, attempt, reason)
    end
  end

  defp maybe_retry_embed(texts, model, key, attempt, reason) do
    if attempt < @embed_max_retries do
      delay = @embed_base_delay_ms * Integer.pow(2, attempt)

      Logger.warning(
        "Embed attempt #{attempt + 1}/#{@embed_max_retries + 1} failed (model=#{model}, " <>
          "texts=#{length(texts)}): #{inspect(reason)}. Retrying in #{delay}ms"
      )

      Process.sleep(delay)
      do_embed(texts, model, key, attempt + 1)
    else
      Logger.error(
        "Embed failed after #{@embed_max_retries + 1} attempts (model=#{model}, " <>
          "texts=#{length(texts)}): #{inspect(reason)}"
      )

      {:error, reason}
    end
  end

  @impl true
  def list_models do
    case api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        case Req.get("#{@base_url}/models", headers: headers(key)) do
          {:ok, %{status: 200, body: %{"data" => models}}} ->
            chat_models =
              models
              |> Enum.filter(&(&1["type"] == "chat" or is_nil(&1["type"])))

            {:ok, chat_models}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, {:http_error, status, resp_body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp api_key do
    Pearl.Config.openrouter_api_key()
  end

  @impl true
  def embedding_model do
    Pearl.Config.embedding_model()
  end

  defp headers(key) do
    [
      {"authorization", "Bearer #{key}"},
      {"content-type", "application/json"}
    ]
  end

  defp finish_stream(_resp), do: :ok
end
