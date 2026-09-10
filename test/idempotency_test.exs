defmodule Adyen123FS.IdempotencyTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Client, TestAdapter}

  test "a persisted key is reused verbatim across caller retries" do
    client =
      TestAdapter.client(fn req ->
        assert Req.Request.get_header(req, "idempotency-key") == ["operation-123"]

        {req,
         Req.Response.new(
           status: 503,
           headers: [{"transient-error", "true"}, {"retry-after", "10"}],
           body: %{"errorCode" => "703"}
         )}
      end)

    for _ <- 1..2 do
      assert {:error, %{retryable: true, headers: %{"retry-after" => ["10"]}}} =
               Client.request(client, :post, "/payments", %{}, idempotency_key: "operation-123")
    end
  end

  test "HTTP retries need both Adyen's permission and an idempotency key" do
    for headers <- [[], [{"transient-error", "false"}], [{"transient-error", "true"}]],
        key <- [nil, "operation"] do
      client =
        TestAdapter.client(fn req ->
          {req, Req.Response.new(status: 429, headers: headers, body: %{})}
        end)

      opts = if key, do: [idempotency_key: key], else: []
      assert {:error, error} = Client.request(client, :post, "/payments", %{}, opts)
      assert error.retryable == (key != nil and headers == [{"transient-error", "true"}])
    end
  end

  test "a keyed timeout is indeterminate and safe to retry with that same key" do
    client = TestAdapter.client(fn req -> {req, %Req.TransportError{reason: :timeout}} end)

    assert {:error, %{kind: :transport, retryable: true}} =
             Client.request(client, :post, "/payments", %{}, idempotency_key: "operation")
  end

  test "unsafe options cannot override the endpoint, credentials or retry policy" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    for opts <- [
          [url: "https://evil.example"],
          [headers: [{"x-api-key", "override"}]],
          [retry: :transient],
          [redirect: true],
          [idempotency_key: ""],
          [idempotency_key: String.duplicate("a", 65)],
          [idempotency_key: "a\r\nb"]
        ] do
      assert {:error, %{kind: :validation}} =
               Client.request(client, :post, "/payments", %{}, opts)
    end
  end

  test "query parameters are encoded without becoming new parameters" do
    client =
      TestAdapter.client(fn req ->
        assert URI.decode_query(req.url.query) == %{"sessionResult" => "abc+/=&x=1"}
        {req, Req.Response.new(status: 200, body: %{})}
      end)

    assert {:ok, _} =
             Client.request(client, :get, "/sessions/id", nil,
               query: %{"sessionResult" => "abc+/=&x=1"}
             )
  end

  test "malformed JSON preserves HTTP response context and cannot mean payment success" do
    client =
      TestAdapter.client(fn req ->
        {req,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: "{invalid"
         )}
      end)

    assert {:error, %{kind: :protocol, status: 200, body: "{invalid"}} =
             Client.request(client, :post, "/payments", %{})
  end

  test "non-JSON error responses retain status and headers" do
    client =
      TestAdapter.client(fn req ->
        {req,
         Req.Response.new(
           status: 502,
           headers: [{"content-type", "text/html"}],
           body: "<html>Bad gateway</html>"
         )}
      end)

    assert {:error, %{kind: :api, status: 502, body: "<html>Bad gateway</html>"}} =
             Client.request(client, :post, "/payments", %{})
  end

  test "inspecting an error cannot expose a response payload or a transport reason" do
    error = %Adyen123FS.Error{
      kind: :api,
      status: 422,
      body: %{"applePayToken" => "private-wallet-token"},
      reason: "private-reason",
      headers: %{"authorization" => ["private-header"]}
    }

    text = inspect(error)
    assert text =~ "422"
    refute text =~ "private-"
  end

  test "serializes and decodes JSON without relying on response content type" do
    client =
      TestAdapter.client(fn req ->
        {req, Req.Response.new(status: 200, body: ~s({"resultCode":"Refused"}))}
      end)

    assert {:ok, %{body: %{"resultCode" => "Refused"}}} =
             Client.request(client, :post, "/payments", %{})
  end

  test "key generator creates distinct UUID v4 values but never submits them implicitly" do
    a = Adyen123FS.idempotency_key()
    b = Adyen123FS.idempotency_key()
    assert a != b

    client =
      TestAdapter.client(fn request ->
        assert Req.Request.get_header(request, "idempotency-key") == []
        {request, Req.Response.new(status: 200, body: %{})}
      end)

    assert {:ok, _} = Client.request(client, :post, "/paymentMethods", %{})
    assert a =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end
end
