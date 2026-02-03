defmodule Pearl.Providers.OpenAI.EmbeddingsTest do
  use ExUnit.Case, async: true

  alias Pearl.Providers.OpenAI.{Client, Embeddings}

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    client = Client.new(api_key: "test-key", base_url: base_url)
    {:ok, bypass: bypass, client: client}
  end

  describe "create/3" do
    test "creates embeddings for single text", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "text-embedding-3-small"
        assert params["input"] == "Hello world"

        response = %{
          "object" => "list",
          "data" => [
            %{
              "object" => "embedding",
              "index" => 0,
              "embedding" => [0.1, 0.2, 0.3, 0.4, 0.5]
            }
          ],
          "model" => "text-embedding-3-small",
          "usage" => %{
            "prompt_tokens" => 2,
            "total_tokens" => 2
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, result} = Embeddings.create(client, "Hello world", "text-embedding-3-small")
      assert result["data"] == [
        %{
          "object" => "embedding",
          "index" => 0,
          "embedding" => [0.1, 0.2, 0.3, 0.4, 0.5]
        }
      ]
    end

    test "creates embeddings for multiple texts", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "text-embedding-3-small"
        assert params["input"] == ["Hello", "World"]

        response = %{
          "object" => "list",
          "data" => [
            %{"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2, 0.3]},
            %{"object" => "embedding", "index" => 1, "embedding" => [0.4, 0.5, 0.6]}
          ],
          "model" => "text-embedding-3-small",
          "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, result} = Embeddings.create(client, ["Hello", "World"], "text-embedding-3-small")
      assert length(result["data"]) == 2
    end

    test "handles API errors", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        response = %{
          "error" => %{
            "message" => "Invalid API key provided",
            "type" => "invalid_request_error",
            "param" => nil,
            "code" => "invalid_api_key"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(response))
      end)

      assert {:error, error} = Embeddings.create(client, "test", "text-embedding-3-small")
      assert error["error"]["code"] == "invalid_api_key"
    end

    test "handles rate limit errors", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        response = %{
          "error" => %{
            "message" => "Rate limit exceeded",
            "type" => "rate_limit_error",
            "param" => nil,
            "code" => "rate_limit_exceeded"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(response))
      end)

      assert {:error, error} = Embeddings.create(client, "test", "text-embedding-3-small")
      assert error["error"]["type"] == "rate_limit_error"
    end

    test "handles network errors", %{bypass: bypass, client: client} do
      Bypass.down(bypass)

      assert {:error, _reason} = Embeddings.create(client, "test", "text-embedding-3-small")
    end
  end
end
