defmodule Pearl.Providers.ClaudeCode do
  @moduledoc """
  Claude Code CLI provider.

  Spawns the `claude` CLI as an Erlang Port for each chat request.
  Parses JSON lines from stdout to extract assistant responses and cost data.

  ## Requirements

  Requires the `claude` CLI to be installed and available on PATH.
  Authentication is handled by the CLI itself (no API key needed in Pearl).

  ## Limitations

  - Embeddings are not supported. Use a different provider for `embedding_provider`.
  - The CLI is spawned fresh per request (no persistent session).
  """

  @behaviour Pearl.Providers.Provider

  require Logger

  @known_models [
    %{"id" => "claude-haiku-4-5-20251001", "name" => "Claude Haiku 4.5"},
    %{"id" => "claude-sonnet-4-5-20250929", "name" => "Claude Sonnet 4.5"},
    %{"id" => "claude-opus-4-6", "name" => "Claude Opus 4.6"}
  ]

  @doc "Finds the claude CLI executable on the system."
  @spec find_cli() :: {:ok, String.t()} | {:error, :cli_not_found}
  def find_cli do
    case Application.get_env(:pearl, :claude_cli_path) do
      nil ->
        case System.find_executable("claude") do
          nil -> {:error, :cli_not_found}
          path -> {:ok, path}
        end

      path ->
        {:ok, path}
    end
  end

  @doc "Builds CLI argument list for a claude invocation."
  @spec build_args(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def build_args(model, prompt, system_prompt) do
    base = [
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      model,
      "--permission-mode",
      "bypassPermissions"
    ]

    system = if system_prompt, do: ["--system-prompt", system_prompt], else: []

    base ++ system ++ ["--print", "--", prompt]
  end

  @doc "Parses a single JSON line from the CLI stdout."
  @spec parse_json_line(String.t()) :: {:text, String.t()} | {:done, map()} | :skip
  def parse_json_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => blocks}}} ->
        text =
          blocks
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join(& &1["text"])

        if text != "", do: {:text, text}, else: :skip

      {:ok, %{"type" => "result"} = result} ->
        {:done,
         Map.take(result, [
           "is_error",
           "session_id",
           "total_cost_usd",
           "duration_ms",
           "num_turns",
           "usage"
         ])}

      _ ->
        :skip
    end
  end

  @impl true
  def chat(model, messages, opts) do
    case find_cli() do
      {:error, _} = err ->
        err

      {:ok, cli_path} ->
        {system_prompt, prompt} = extract_messages(messages)
        args = build_args(model, prompt, system_prompt)
        cd = Keyword.get(opts, :cd)

        case Keyword.get(opts, :stream, false) do
          false -> chat_sync(cli_path, args, cd)
          true -> chat_stream(cli_path, args, cd)
        end
    end
  end

  defp extract_messages(messages) do
    system =
      messages
      |> Enum.filter(&(&1.role == :system or &1[:role] == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n")

    system_prompt = if system == "", do: nil, else: system

    # Use the last user message as the prompt
    user_prompt =
      messages
      |> Enum.filter(&(&1.role == :user or &1[:role] == "user"))
      |> List.last()
      |> case do
        nil -> ""
        msg -> msg.content
      end

    {system_prompt, user_prompt}
  end

  # Opens the Claude CLI as an Erlang Port with stdin closed.
  #
  # The Claude CLI blocks when stdin is a pipe (as created by spawn_executable).
  # We work around this by wrapping through /bin/sh with `< /dev/null` to close
  # stdin, while preserving safe argument passing via sh's positional parameters.
  @spec open_cli_port(String.t(), [String.t()], String.t() | nil) :: port()
  defp open_cli_port(cli_path, args, cd) do
    port_opts = [
      :binary,
      :exit_status,
      {:args, ["-c", ~S(exec "$0" "$@" < /dev/null), cli_path | args]},
      {:line, 1_048_576}
    ]

    port_opts = if cd, do: [{:cd, cd} | port_opts], else: port_opts

    Port.open({:spawn_executable, "/bin/sh"}, port_opts)
  end

  defp chat_sync(cli_path, args, cd) do
    port = open_cli_port(cli_path, args, cd)
    ref = Port.monitor(port)
    result = collect_sync(port, ref, [])
    Port.demonitor(ref, [:flush])
    result
  end

  defp collect_sync(port, ref, texts) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case parse_json_line(line) do
          {:text, text} -> collect_sync(port, ref, [text | texts])
          {:done, _result} -> finish_port(port, texts)
          :skip -> collect_sync(port, ref, texts)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        # Line too long, skip partial data
        collect_sync(port, ref, texts)

      {^port, {:exit_status, 0}} ->
        {:ok, texts |> Enum.reverse() |> Enum.join()}

      {^port, {:exit_status, code}} ->
        {:error, {:cli_error, code}}

      {:DOWN, ^ref, :port, ^port, _reason} ->
        # Port died without sending exit_status (e.g. zombie not reaped)
        if texts == [],
          do: {:error, {:cli_error, :port_closed}},
          else: {:ok, texts |> Enum.reverse() |> Enum.join()}
    after
      600_000 ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp finish_port(port, texts) do
    # Drain remaining messages until exit
    receive do
      {^port, {:exit_status, _}} -> {:ok, texts |> Enum.reverse() |> Enum.join()}
      {^port, _} -> finish_port(port, texts)
    after
      10_000 ->
        safe_close(port)
        {:ok, texts |> Enum.reverse() |> Enum.join()}
    end
  end

  defp chat_stream(cli_path, args, cd) do
    port = open_cli_port(cli_path, args, cd)

    stream =
      Stream.resource(
        fn -> port end,
        &next_stream_chunk/1,
        &close_port/1
      )

    {:ok, stream}
  end

  defp next_stream_chunk(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case parse_json_line(line) do
          {:text, text} -> {[text], port}
          {:done, _result} -> {:halt, port}
          :skip -> {[], port}
        end

      {^port, {:data, {:noeol, _partial}}} ->
        {[], port}

      {^port, {:exit_status, _}} ->
        {:halt, port}
    after
      600_000 -> {:halt, port}
    end
  end

  defp close_port(port), do: safe_close(port)

  @impl true
  def embed(_texts) do
    {:error, :not_supported}
  end

  @impl true
  def list_models do
    {:ok, @known_models}
  end

  @impl true
  def embedding_model do
    ""
  end
end
