defmodule Adyen123FS.CheckoutTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Checkout, TestAdapter}

  @payment %{
    "merchantAccount" => "Merchant",
    "reference" => "registration-42",
    "amount" => %{"currency" => "EUR", "value" => 15000},
    "returnUrl" => "https://signup.example/return"
  }
  @key [idempotency_key: "persisted-operation"]

  for {type, details} <- [
        {"scheme",
         %{
           "encryptedCardNumber" => "test-encrypted",
           "encryptedExpiryMonth" => "03",
           "encryptedExpiryYear" => "2030",
           "encryptedSecurityCode" => "encrypted"
         }},
        {"applepay", %{"applePayToken" => "apple-token"}},
        {"googlepay", %{"googlePayToken" => "google-token"}},
        {"alma", %{}}
      ] do
    @type_name type
    @details details
    test "create_payment forwards complete #{@type_name} payload and action" do
      body =
        Map.merge(@payment, %{
          "paymentMethod" => Map.put(@details, "type", @type_name),
          "browserInfo" => %{"userAgent" => "test"},
          "origin" => "https://signup.example",
          "channel" => "Web",
          "additionalData" => %{"alma.installments_count" => 3},
          "shopperEmail" => "test@example.com",
          "lineItems" => [%{"id" => "course", "quantity" => 1}]
        })

      action = %{
        "type" => "redirect",
        "url" => "https://issuer.example",
        "paymentData" => "opaque"
      }

      client =
        TestAdapter.client(fn req ->
          assert req.method == :post
          assert req.url.path == "/v72/payments"
          assert Jason.decode!(req.body) == body
          assert Req.Request.get_header(req, "idempotency-key") == ["persisted-operation"]

          {req,
           Req.Response.new(
             status: 200,
             body: %{"resultCode" => "RedirectShopper", "action" => action}
           )}
        end)

      assert {:ok, %{body: %{"action" => ^action}}} = Checkout.create_payment(client, body, @key)
    end
  end

  for details <- [%{"redirectResult" => "opaque-return"}, %{"threeDSResult" => "opaque-3ds"}] do
    @details_payload details
    test "submit_details accepts #{inspect(details)} without requiring paymentData" do
      client = expect_request(:post, "/payments/details", %{"details" => @details_payload})
      assert {:ok, _} = Checkout.submit_details(client, %{"details" => @details_payload}, @key)
    end
  end

  test "payment methods and sessions use their actual public functions" do
    client = expect_request(:post, "/paymentMethods", %{"merchantAccount" => "Merchant"})
    assert {:ok, _} = Checkout.payment_methods(client, %{"merchantAccount" => "Merchant"})
    client = expect_request(:post, "/sessions", @payment)
    assert {:ok, _} = Checkout.create_session(client, @payment, @key)
  end

  test "session results require and encode sessionResult" do
    client =
      TestAdapter.client(fn req ->
        assert req.method == :get
        assert req.url.path == "/v72/sessions/CS123"
        assert URI.decode_query(req.url.query) == %{"sessionResult" => "result+/=&"}
        assert req.body == nil
        {req, Req.Response.new(status: 200, body: %{"status" => "completed"})}
      end)

    assert {:ok, _} = Checkout.get_session(client, "CS123", "result+/=&")
    assert {:error, %{kind: :validation}} = Checkout.get_session(client, "CS123", "")
  end

  test "session updates send PATCH with sessionData and amount" do
    body = %{"sessionData" => "opaque", "amount" => @payment["amount"]}
    client = expect_request(:patch, "/sessions/CS123", body)
    assert {:ok, _} = Checkout.update_session(client, "CS123", body)
  end

  test "Apple Pay merchant validation calls Adyen rather than a shopper-supplied URL" do
    body = %{
      "displayName" => "123Fahrschule",
      "domainName" => "signup.example",
      "merchantIdentifier" => "merchant.example"
    }

    client = expect_request(:post, "/applePay/sessions", body)
    assert {:ok, _} = Checkout.apple_pay_session(client, body, @key)
  end

  test "missing required fields and idempotency keys are rejected before network access" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    for missing <- ["amount", "merchantAccount", "reference", "returnUrl", "paymentMethod"] do
      body = Map.put(@payment, "paymentMethod", %{"type" => "scheme"}) |> Map.delete(missing)
      assert {:error, %{kind: :validation}} = Checkout.create_payment(client, body, @key)
    end

    assert {:error, %{kind: :validation}} = Checkout.create_session(client, @payment)
    assert {:error, %{kind: :validation}} = Checkout.submit_details(client, %{}, @key)

    assert {:error, %{kind: :validation}} =
             Checkout.payment_methods(client, %{merchantAccount: "Merchant"})
  end

  test "invalid amounts never get sent, zero-value card verification remains supported" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    for amount <- [
          %{"currency" => "EUR", "value" => 1.5},
          %{"currency" => "EUR", "value" => -1},
          %{"currency" => "eur", "value" => 100}
        ] do
      assert {:error, %{kind: :validation}} =
               Checkout.create_session(client, Map.put(@payment, "amount", amount), @key)
    end

    body = Map.put(@payment, "amount", %{"currency" => "EUR", "value" => 0})

    assert {:ok, _} =
             Checkout.create_session(expect_request(:post, "/sessions", body), body, @key)
  end

  defp expect_request(method, path, body) do
    TestAdapter.client(fn req ->
      assert req.method == method
      assert req.url.path == "/v72" <> path
      assert Jason.decode!(req.body) == body
      {req, Req.Response.new(status: 200, body: %{})}
    end)
  end

  test "stored method query extensions cannot crash listing or deletion" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    for extra <- [%{"nested" => 1}, [1, 2], {1, 2}] do
      query = %{
        "merchantAccount" => "Merchant",
        "shopperReference" => "shopper",
        "extra" => extra
      }

      assert {:error, %{kind: :validation}} = Checkout.list_stored_payment_methods(client, query)

      assert {:error, %{kind: :validation}} =
               Checkout.delete_stored_payment_method(client, "T1", query)
    end
  end

  test "non-map bodies and incomplete amounts fail before network access" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)
    assert {:error, %{kind: :validation}} = Checkout.create_payment(client, "not-a-map", @key)

    for amount <- [%{"value" => 1}, %{"currency" => "EUR"}] do
      assert {:error, %{kind: :validation}} =
               Checkout.create_session(client, Map.put(@payment, "amount", amount), @key)
    end
  end
end
