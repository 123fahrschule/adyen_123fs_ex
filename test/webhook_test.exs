defmodule Adyen123FS.WebhookTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.Webhook
  # Public Adyen documentation key and signature, never merchant credentials.
  @key "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056"
  @fixture File.read!(Path.join(__DIR__, "fixtures/standard_webhook.json")) |> Jason.decode!()
  @item hd(@fixture["notificationItems"])["NotificationRequestItem"]
  @contract __DIR__
            |> Path.join("fixtures/webhooks_v1_contract.json")
            |> File.read!()
            |> Jason.decode!()

  test "event catalog exactly matches the sorted pinned Webhooks v1 enum" do
    assert length(@contract["event_codes"]) == 40
    assert apply(Webhook, :event_codes, []) == Enum.sort(@contract["event_codes"])
    for code <- @contract["event_codes"], do: assert(apply(Webhook, :known_event_code?, [code]))

    for code <- ["NOT_A_REAL_EVENT", "authorisation", "", nil, :AUTHORISATION, 1, %{}, []],
        do: refute(apply(Webhook, :known_event_code?, [code]))
  end

  test "signed fields distinguish schema requirements from authenticated values" do
    expected =
      @contract["required"]
      |> List.delete("eventDate")
      |> Kernel.++(["originalReference"])
      |> Enum.sort()

    assert apply(Webhook, :signed_fields, []) |> Enum.sort() == expected
  end

  test "unknown event codes can still be authenticated and routed to reconciliation" do
    item =
      @item
      |> Map.put("eventCode", "NOT_A_REAL_EVENT")
      |> put_in(
        ["additionalData", "hmacSignature"],
        "Ya/QMzZsKMvNxZovc55YAmjEUtZ7TLVD+MjugIkAvqc="
      )

    assert Webhook.verify_standard(item, @key)

    assert {:ok, [^item]} =
             Webhook.verify_standard_request(
               %{"notificationItems" => [%{"NotificationRequestItem" => item}]},
               @key
             )

    refute apply(Webhook, :known_event_code?, [item["eventCode"]])
  end

  test "eventDate, paymentMethod, reason and additional metadata are not authenticated" do
    item =
      @item
      |> Map.put("eventDate", "untrusted")
      |> Map.put("paymentMethod", "untrusted")
      |> Map.put("reason", "untrusted")
      |> put_in(["additionalData", "unsigned"], "untrusted")

    assert Webhook.verify_standard(item, @key)

    for field <- ["eventDate", "paymentMethod", "reason", "additionalData"],
        do: refute(field in apply(Webhook, :signed_fields, []))
  end

  test "validates the independent signature published by Adyen" do
    assert Webhook.verify_standard(@item, @key)
    assert {:ok, [@item]} == Webhook.verify_standard_request(@fixture, @key)
  end

  test "key rotation accepts current or previous key" do
    assert Webhook.verify_standard(@item, [String.duplicate("ab", 32), String.downcase(@key)])
    refute Webhook.verify_standard(@item, [String.duplicate("ab", 32)])
  end

  test "UTF-8 and separators follow Standard webhook canonicalization, not legacy HPP escaping" do
    item =
      @item
      |> Map.put("merchantReference", "order:42\\ä")
      |> put_in(
        ["additionalData", "hmacSignature"],
        "pLXgH5pXPbCVX/IpL/OkxgvQk8OQiFiFgTVSEjsVsS4="
      )

    assert Webhook.verify_standard(item, @key)
  end

  test "changing any signed business field invalidates the signature" do
    for {field, value} <- [
          {"pspReference", "other"},
          {"originalReference", "other"},
          {"merchantAccountCode", "other"},
          {"merchantReference", "other"},
          {"amount", %{"value" => 1131, "currency" => "EUR"}},
          {"amount", %{"value" => 1130, "currency" => "USD"}},
          {"eventCode", "CAPTURE"},
          {"success", "false"}
        ] do
      refute Webhook.verify_standard(Map.put(@item, field, value), @key)
    end
  end

  test "malformed keys, signatures and nested payloads fail closed without raising" do
    for key <- [nil, "", "odd", String.duplicate("z", 64), %{}, [], [nil]] do
      refute Webhook.verify_standard(@item, key)
    end

    for item <- [
          nil,
          [],
          %{},
          Map.put(@item, "amount", "wrong"),
          Map.put(@item, "additionalData", []),
          Map.put(@item, "success", %{}),
          Map.put(@item, "originalReference", []),
          Map.put(@item, "originalReference", false),
          put_in(@item, ["additionalData", "hmacSignature"], "bad-base64"),
          put_in(@item, ["additionalData", "hmacSignature"], Base.encode64("short"))
        ] do
      refute Webhook.verify_standard(item, @key)
    end
  end

  test "verifies every item before returning a batch" do
    bad = %{"NotificationRequestItem" => Map.put(@item, "success", "false")}
    batch = Map.put(@fixture, "notificationItems", @fixture["notificationItems"] ++ [bad])
    assert {:error, :invalid_signature} = Webhook.verify_standard_request(batch, @key)

    for payload <- [%{}, %{"notificationItems" => []}, %{"notificationItems" => [nil]}, nil] do
      assert {:error, _} = Webhook.verify_standard_request(payload, @key)
    end
  end

  test "body-signed webhooks use exact original bytes" do
    raw = ~s({"type":"recurring.token.created","data":{"shopperReference":"ä"}})
    signature = "9TmwmqYbzJB0d656L6lJEbOcu7w//WdzLjVJfDW8pg4="
    assert Webhook.verify_body(raw, signature, @key)
    refute Webhook.verify_body(raw <> "\n", signature, @key)
    refute Webhook.verify_body(Jason.decode!(raw), signature, @key)
  end
end
