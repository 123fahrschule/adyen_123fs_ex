defmodule Adyen123FS.APIContractTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Checkout, Client, TestAdapter}

  @contract File.read!(Path.join(__DIR__, "fixtures/checkout_v72_contract.json"))
            |> Jason.decode!()
  @operations [
    {:payment_methods, "POST /paymentMethods", :body_optional_key},
    {:card_details, "POST /cardDetails", :body_optional_key},
    {:create_payment_link, "POST /paymentLinks", :body},
    {:get_payment_link, "GET /paymentLinks/{linkId}", :resource},
    {:expire_payment_link, "PATCH /paymentLinks/{linkId}", :expire_link},
    {:create_payment, "POST /payments", :body},
    {:submit_details, "POST /payments/details", :body},
    {:create_session, "POST /sessions", :body},
    {:get_session, "GET /sessions/{sessionId}", :session_result},
    {:update_session, "PATCH /sessions/{sessionId}", :update_session},
    {:apple_pay_session, "POST /applePay/sessions", :body},
    {:cancel_by_reference, "POST /cancels", :body},
    {:capture, "POST /payments/{paymentPspReference}/captures", :modification},
    {:refund, "POST /payments/{paymentPspReference}/refunds", :modification},
    {:cancel, "POST /payments/{paymentPspReference}/cancels", :modification},
    {:reverse, "POST /payments/{paymentPspReference}/reversals", :modification},
    {:update_amount, "POST /payments/{paymentPspReference}/amountUpdates", :modification},
    {:list_stored_payment_methods, "GET /storedPaymentMethods", :query},
    {:store_payment_method, "POST /storedPaymentMethods", :body},
    {:delete_stored_payment_method, "DELETE /storedPaymentMethods/{storedPaymentMethodId}",
     :delete}
  ]

  test "every public Checkout function has a pinned contract and service guard" do
    listed = @operations |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    exported = Checkout.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.equal?(listed, exported)
  end

  for {function, operation, kind} <- @operations do
    @function function
    @operation operation
    @kind kind
    @specification @contract["operations"][operation]

    test "#{function} rejects a Data Protection client before network access" do
      TestAdapter.register(fn _ -> flunk("wrong service must not reach Adyen") end)
      client = Client.new(api_key: "key", service: :data_protection, adapter: TestAdapter)
      body = sample_body(@specification["required_body"])

      assert {:error,
              %{kind: :validation, message: "client is configured for a different Adyen service"}} =
               invoke(client, @function, @kind, body)
    end

    test "#{function} obeys the pinned Adyen v72 method, path and required field contract" do
      body = sample_body(@specification["required_body"])
      [method, path] = String.split(@operation, " ", parts: 2)
      path = Regex.replace(~r/\{[^}]+\}/, path, "RESOURCE123")

      client =
        TestAdapter.client(fn request ->
          assert String.upcase(Atom.to_string(request.method)) == method
          assert request.url.path == "/v72" <> path
          if body != %{}, do: assert(Jason.decode!(request.body) == body)

          if @kind == :body_optional_key,
            do: assert(Req.Request.get_header(request, "idempotency-key") == [])

          if @kind == :expire_link do
            assert Req.Request.get_header(request, "idempotency-key") == []
            assert @specification["body_enums"]["status"] == [body["status"]]
          end

          query = URI.decode_query(request.url.query || "")
          for key <- @specification["required_query"], do: assert(Map.has_key?(query, key))
          {request, Req.Response.new(status: 200, body: %{})}
        end)

      assert {:ok, _} = invoke(client, @function, @kind, body)
    end

    if kind in [:body, :body_optional_key, :modification, :update_session] do
      test "#{function} rejects missing or wrongly typed required fields" do
        body = sample_body(@specification["required_body"])
        client = TestAdapter.client(fn _ -> flunk("invalid request must not reach Adyen") end)

        for {field, type} <- @specification["required_body"] do
          assert {:error, %{kind: :validation}} =
                   invoke(client, @function, @kind, Map.delete(body, field))

          wrong = if type == "object", do: "wrong", else: %{"wrong" => "type"}

          assert {:error, %{kind: :validation}} =
                   invoke(client, @function, @kind, Map.put(body, field, wrong))
        end
      end
    end
  end

  defp sample_body(required) do
    Map.new(required, fn
      {"amount", _} -> {"amount", %{"currency" => "EUR", "value" => 1000}}
      {"paymentMethod", _} -> {"paymentMethod", %{"type" => "scheme"}}
      {"details", _} -> {"details", %{"redirectResult" => "opaque"}}
      {"status", _} -> {"status", "expired"}
      {key, _} -> {key, "test-value"}
    end)
  end

  test "card discovery preserves optional fields and allows an explicit operation key" do
    for options <- [[], [idempotency_key: "discovery-key"]] do
      body = %{
        "merchantAccount" => "Merchant",
        "encryptedCardNumber" => "test_encrypted",
        "countryCode" => "DE",
        "supportedBrands" => ["visa", "mc"],
        "futureField" => %{"preserved" => true}
      }

      response = %{"brands" => [%{"type" => "visa", "supported" => true}]}

      client =
        TestAdapter.client(fn req ->
          assert req.method == :post
          assert req.url.path == "/v72/cardDetails"
          assert Jason.decode!(req.body) == body

          assert Req.Request.get_header(req, "idempotency-key") ==
                   List.wrap(options[:idempotency_key])

          {req, Req.Response.new(status: 200, body: response)}
        end)

      assert {:ok, %{body: ^response}} = Checkout.card_details(client, body, options)
    end
  end

  defp invoke(client, function, :body_optional_key, body),
    do: apply(Checkout, function, [client, body])

  defp invoke(client, function, kind, _) when kind in [:resource, :expire_link],
    do: apply(Checkout, function, [client, "RESOURCE123"])

  test "payment links preserve options and return a link rather than a payment outcome" do
    body = %{
      "amount" => %{"currency" => "EUR", "value" => 10000},
      "merchantAccount" => "Merchant",
      "reference" => "voucher-purchase",
      "expiresAt" => "2026-09-11T12:00:00Z",
      "shopperEmail" => "parent@example.com",
      "description" => "Driving lesson voucher",
      "countryCode" => "DE",
      "reusable" => false,
      "allowedPaymentMethods" => ["scheme"],
      "blockedPaymentMethods" => ["ideal"],
      "lineItems" => [%{"id" => "voucher"}],
      "manualCapture" => true,
      "storePaymentMethodMode" => "disabled",
      "recurringProcessingModel" => "CardOnFile",
      "shopperReference" => "shopper-1"
    }

    response = %{
      "id" => "LINK123",
      "url" => "https://checkoutshopper-test.adyen.com/test-link",
      "status" => "active"
    }

    client =
      TestAdapter.client(fn req ->
        assert Jason.decode!(req.body) == body
        assert Req.Request.get_header(req, "idempotency-key") == ["link-operation"]
        {req, Req.Response.new(status: 201, body: response)}
      end)

    assert {:ok, %{status: 201, body: ^response}} =
             Checkout.create_payment_link(client, body, idempotency_key: "link-operation")

    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    assert {:error, %{kind: :validation}} =
             Checkout.create_payment_link(client, body, [])

    refute function_exported?(Checkout, :create_payment_link, 2)
  end

  test "link retrieval and expiration reject unsafe or oversized identifiers" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    for function <- [:get_payment_link, :expire_payment_link],
        id <- [nil, "", "../payments", "LINK?status=paid", String.duplicate("x", 1025)] do
      assert {:error, %{kind: :validation}} = apply(Checkout, function, [client, id])
    end
  end

  test "link expiration has a fixed body and never marks an uncertain PATCH retryable" do
    client =
      TestAdapter.client(fn req ->
        assert req.method == :patch
        assert req.url.path == "/v72/paymentLinks/LINK123"
        assert Jason.decode!(req.body) == %{"status" => "expired"}
        assert Req.Request.get_header(req, "idempotency-key") == []
        {req, %Req.TransportError{reason: :timeout}}
      end)

    assert {:error, %{kind: :transport, retryable: false}} =
             Checkout.expire_payment_link(client, "LINK123")
  end

  defp invoke(client, function, :body, body),
    do: apply(Checkout, function, [client, body, [idempotency_key: "operation"]])

  defp invoke(client, function, :modification, body),
    do: apply(Checkout, function, [client, "RESOURCE123", body, [idempotency_key: "operation"]])

  defp invoke(client, function, :update_session, body),
    do: apply(Checkout, function, [client, "RESOURCE123", body])

  defp invoke(client, function, :session_result, _),
    do: apply(Checkout, function, [client, "RESOURCE123", "opaque-result"])

  defp invoke(client, function, :query, _),
    do:
      apply(Checkout, function, [
        client,
        %{"merchantAccount" => "Merchant", "shopperReference" => "Shopper"}
      ])

  defp invoke(client, function, :delete, _),
    do:
      apply(Checkout, function, [
        client,
        "RESOURCE123",
        %{"merchantAccount" => "Merchant", "shopperReference" => "Shopper"}
      ])
end
