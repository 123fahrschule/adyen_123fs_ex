defmodule Adyen123FS.ErrorTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Client, TestAdapter}

  test "API errors expose bounded diagnostic codes without response messages or headers" do
    client =
      response(422, %{
        "errorCode" => "14_002",
        "errorType" => "validation",
        "message" => "secret-payload"
      })

    assert {:error, error} = Client.request(client, :post, "/payments", %{})

    assert error.message ==
             "Adyen API error: status=422 retryable=false errorCode=14_002 errorType=validation"

    assert error.body["message"] == "secret-payload"
    refute inspect(error) =~ "secret"
  end

  test "untrusted diagnostic fields cannot become log messages" do
    for value <- [
          "secret@example.com",
          "123\nsecret",
          "secret",
          %{"secret" => true},
          ["secret"],
          nil
        ] do
      client =
        response(503, %{"errorCode" => value, "errorType" => value, "message" => "secret"}, [
          {"transient-error", "true"},
          {"secret", "secret"}
        ])

      assert {:error, error} =
               Client.request(client, :post, "/payments", %{}, idempotency_key: "operation")

      assert error.message == "Adyen API error: status=503 retryable=true"
    end
  end

  test "protocol errors describe the failure without including the unexpected payload" do
    client = response(200, "secret-invalid-json")
    assert {:error, error} = Client.request(client, :get, "/storedPaymentMethods", nil)

    assert error.message ==
             "Adyen protocol error: status=200 retryable=false unexpected response body"
  end

  test "transport errors expose known categories but never raw exception messages" do
    for {reason, suffix} <- [
          {%Req.TransportError{reason: :timeout}, " reason=timeout"},
          {%Req.TransportError{reason: {:tls_alert, "secret"}}, ""},
          {%RuntimeError{message: "secret"}, ""}
        ] do
      client = TestAdapter.client(fn req -> {req, reason} end)

      assert {:error, error} =
               Client.request(client, :post, "/payments", %{}, idempotency_key: "operation")

      assert error.message == "Adyen transport error: retryable=true" <> suffix
      assert error.reason == reason
    end
  end

  defp response(status, body, headers \\ []) do
    TestAdapter.client(fn req ->
      {req, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end
end
