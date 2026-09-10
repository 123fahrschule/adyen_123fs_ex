defmodule Adyen123FS.ClientTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.Client

  test "explicit configuration works without global application settings" do
    client = Client.new(api_key: "test-secret")
    assert client.base_url == "https://checkout-test.adyen.com/v72"
    refute inspect(client) =~ "test-secret"
  end

  test "live endpoints require a merchant prefix" do
    assert_raise ArgumentError, fn -> Client.new(api_key: "key", environment: :live) end
    client = Client.new(api_key: "key", environment: :live, live_prefix: "1797-acme")
    assert client.base_url == "https://1797-acme-checkout-live.adyenpayments.com/checkout/v72"
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

  test "regional live endpoints are explicit" do
    client = Client.new(api_key: "key", environment: :live, live_prefix: "acme", region: :us)
    assert client.base_url == "https://acme-checkout-live-us.adyenpayments.com/checkout/v72"
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
end
