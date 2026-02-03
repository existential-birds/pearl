defmodule Pearl.Providers.OpenAI.ClientTest do
  use ExUnit.Case, async: true

  alias Pearl.Providers.OpenAI.Client

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "new/1" do
    test "creates client with provided API key" do
      client = Client.new(api_key: "sk-test-key")
      assert %Tesla.Client{} = client
    end

    test "creates client with API key from environment" do
      original = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "sk-env-key")

      client = Client.new()
      assert %Tesla.Client{} = client

      if original do
        System.put_env("OPENAI_API_KEY", original)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end

    test "raises when API key is not provided or in environment" do
      original = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      assert_raise RuntimeError, "OPENAI_API_KEY not set", fn ->
        Client.new()
      end

      if original do
        System.put_env("OPENAI_API_KEY", original)
      end
    end

    test "accepts custom base_url" do
      client = Client.new(api_key: "test-key", base_url: "https://custom.api.com")
      assert %Tesla.Client{} = client
    end

    test "accepts custom timeout" do
      client = Client.new(api_key: "test-key", timeout: 30_000)
      assert %Tesla.Client{} = client
    end
  end

  describe "post/3" do
    test "makes successful POST request", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"key" => "value"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"result" => "success"}))
      end)

      client = Client.new(api_key: "test-key", base_url: base_url)
      {:ok, response} = Client.post(client, "/v1/test", %{key: "value"})

      assert response.status == 200
      assert response.body == %{"result" => "success"}
    end

    test "includes authorization header", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-api-key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end)

      client = Client.new(api_key: "test-api-key", base_url: base_url)
      Client.post(client, "/v1/test", %{})
    end
  end

  describe "handle_response/2" do
    test "returns ok tuple for successful responses" do
      response = {:ok, %Tesla.Env{status: 200, body: %{"data" => "test"}}}
      assert {:ok, %{"data" => "test"}} = Client.handle_response(response, [])
    end

    test "returns error tuple for 4xx responses" do
      response = {:ok, %Tesla.Env{
        status: 400,
        body: %{
          "error" => %{
            "message" => "Bad request",
            "type" => "invalid_request_error",
            "code" => nil
          }
        }
      }}

      assert {:error, body} = Client.handle_response(response, [])
      assert body["error"]["message"] == "Bad request"
    end

    test "returns error tuple for 5xx responses" do
      response = {:ok, %Tesla.Env{
        status: 500,
        body: %{
          "error" => %{
            "message" => "Internal server error",
            "type" => "server_error",
            "code" => nil
          }
        }
      }}

      assert {:error, body} = Client.handle_response(response, [])
      assert body["error"]["message"] == "Internal server error"
    end

    test "returns error tuple for network errors" do
      response = {:error, :timeout}
      assert {:error, :timeout} = Client.handle_response(response, [])
    end
  end
end
