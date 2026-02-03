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
