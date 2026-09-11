defmodule Adyen123FS.ClientTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.Client

  test "explicit configuration works without global application settings" do
    client = Client.new(api_key: "test-secret")
    assert client.base_url == "https://checkout-test.adyen.com/v72"
    refute inspect(client) =~ "test-secret"
    refute inspect(client.request) =~ "test-secret"
    refute inspect(%{client: client, request: client.request}, limit: :infinity) =~ "test-secret"
    assert Req.Request.get_header(client.request, "x-api-key") == []
  end

  test "API keys reject whitespace and control characters without exposing their value" do
    for key <- [
          " secret",
          "secret ",
          "secret\t",
          "sec ret",
          "secret\n",
          "secret\r",
          "secret\0",
          "secret\x7f"
        ] do
      error = assert_raise ArgumentError, fn -> Client.new(api_key: key) end
      refute Exception.message(error) =~ "secret"
    end
  end

  test "live endpoints require a merchant prefix" do
    assert_raise ArgumentError, fn -> Client.new(api_key: "key", environment: :live) end
    client = Client.new(api_key: "key", environment: :live, live_prefix: "1797-acme")
    assert client.base_url == "https://1797-acme-checkout-live.adyenpayments.com/checkout/v72"
  end

  test "service determines the API host and default version without sharing Checkout prefixes" do
    assert Map.get(Client.new(api_key: "test-secret"), :service) == :checkout

    for {environment, domain} <- [test: "ca-test", live: "ca-live"] do
      client =
        Client.new(api_key: "test-secret", service: :data_protection, environment: environment)

      assert client.service == :data_protection
      assert client.base_url == "https://#{domain}.adyen.com/ca/services/DataProtectionService/v1"
      refute inspect(client) =~ "test-secret"
      refute inspect(client.request) =~ "test-secret"
      assert inspect(client) =~ "data_protection"
    end

    client = Client.new(api_key: "key", service: :data_protection, api_version: 2)
    assert client.base_url == "https://ca-test.adyen.com/ca/services/DataProtectionService/v2"
  end

  test "unsupported services and irrelevant prefixes fail as programmer configuration" do
    for options <- [
          [service: :unknown],
          [service: nil],
          [service: "checkout"],
          [service: :data_protection, environment: :typo],
          [service: :data_protection, live_prefix: "company"],
          [service: :data_protection, environment: :live, live_prefix: nil]
        ] do
      assert_raise ArgumentError, fn -> Client.new([api_key: "key"] ++ options) end
    end
  end

  test "rejects invalid configuration without exposing secrets" do
    for options <- [
          [],
          [api_key: ""],
          [api_key: "key", environment: :typo],
          [api_key: "key", environment: :live, live_prefix: "x/attacker"],
          [api_key: "key", api_version: "v72"],
          [api_key: "key", receive_timeout: 0]
        ] do
      assert_raise ArgumentError, fn -> Client.new(options) end
    end
  end

  test "rejects unsupported region options instead of inventing a Checkout hostname" do
    assert_raise ArgumentError, fn ->
      Client.new(api_key: "key", environment: :live, live_prefix: "acme", region: :us)
    end
  end

  test "requests send JSON and API credentials with retries and redirects disabled" do
    client =
      Adyen123FS.TestAdapter.client(fn req ->
        assert req.url == URI.parse("https://checkout-test.adyen.com/v72/paymentMethods")
        assert Req.Request.get_header(req, "x-api-key") == ["key"]
        assert Jason.decode!(req.body) == %{"merchantAccount" => "Merchant"}
        assert req.options.retry == false
        assert req.options.redirect == false
        {req, Req.Response.new(status: 200, body: %{"paymentMethods" => []})}
      end)

    assert {:ok, response} =
             Client.request(client, :post, "/paymentMethods", %{"merchantAccount" => "Merchant"})

    assert response.body == %{"paymentMethods" => []}
    assert response.status == 200
  end

  test "HTTP errors preserve response headers and body" do
    client =
      Adyen123FS.TestAdapter.client(fn req ->
        {req,
         Req.Response.new(
           status: 503,
           headers: [{"transient-error", "false"}, {"retry-after", "30"}],
           body: %{"errorCode" => "703"}
         )}
      end)

    assert {:error, error} = Client.request(client, :post, "/payments", %{})
    assert error.kind == :api
    assert error.status == 503
    assert error.body["errorCode"] == "703"
    assert error.headers["retry-after"] == ["30"]
    refute error.retryable
  end

  test "transport errors are returned without raising or retrying" do
    client =
      Adyen123FS.TestAdapter.client(fn req ->
        {req, %Req.TransportError{reason: :timeout}}
      end)

    assert {:error, %{kind: :transport, retryable: false}} =
             Client.request(client, :post, "/payments", %{})
  end

  test "path injection is rejected before sending credentials" do
    client = Adyen123FS.TestAdapter.client(fn _ -> flunk("must not send") end)

    for path <- [
          "https://evil.example",
          "//evil.example",
          "/payments/../cancels",
          "/payments?query=1"
        ] do
      assert {:error, %{kind: :validation}} = Client.request(client, :post, path, %{})
    end
  end

  test "invalid request inputs return validation errors before invoking the adapter" do
    client = Adyen123FS.TestAdapter.client(fn _ -> flunk("must not send") end)

    for {method, body, options} <- [
          {:put, %{}, []},
          {:head, %{}, []},
          {:post, %{"pid" => self()}, []},
          {:post, "not-a-map", []}
        ] do
      assert {:error, %{kind: :validation, retryable: false}} =
               Client.request(client, method, "/payments", body, options)
    end

    for query <- [
          "not-a-map",
          ~D[2026-09-10],
          %{:atom => "value"},
          %{{1, 2} => "value"},
          %{"a" => %{"b" => 1}},
          %{"a" => [1, 2]},
          %{"a" => {1, 2}}
        ] do
      assert {:error, %{kind: :validation, retryable: false}} =
               Client.request(client, :get, "/storedPaymentMethods", nil, query: query)
    end
  end

  test "scalar query values survive URL encoding" do
    client =
      Adyen123FS.TestAdapter.client(fn req ->
        assert URI.decode_query(req.url.query) ==
                 %{"string" => "ä+/=&", "integer" => "12", "boolean" => "false", "nil" => ""}

        {req, Req.Response.new(status: 200, body: %{})}
      end)

    assert {:ok, _} =
             Client.request(client, :get, "/storedPaymentMethods", nil,
               query: %{"string" => "ä+/=&", "integer" => 12, "boolean" => false, "nil" => nil}
             )
  end

  test "unsupported response body types return protocol errors" do
    client =
      Adyen123FS.TestAdapter.client(fn req ->
        {req, Req.Response.new(status: 200, body: {:unexpected, :adapter_body})}
      end)

    assert {:error, %{kind: :protocol, retryable: false}} =
             Client.request(client, :get, "/storedPaymentMethods", nil)
  end
end
