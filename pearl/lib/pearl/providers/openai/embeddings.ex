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
