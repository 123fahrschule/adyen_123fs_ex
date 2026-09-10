defmodule Adyen123FS.WebhookPlugTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.WebhookPlug
  @key "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056"
  @raw File.read!(Path.join(__DIR__, "fixtures/standard_webhook.json"))

  defmodule ChunkAdapter do
    # Force real Plug.Conn.read_body/2 through multiple adapter reads.
    def read_req_body([head | tail], _options),
      do: {if(tail == [], do: :ok, else: :more), head, tail}

    def read_req_body(:failed, _options), do: {:error, :timeout}
    def send_resp(_, status, headers, body), do: {:ok, body, {status, headers}}
  end

  test "acknowledges only after the entire verified batch is durably accepted" do
    parent = self()

    options =
      options(
        persist: fn items ->
          assert length(items) == 1
          send(parent, :stored)
          :ok
        end
      )

    conn = WebhookPlug.call(conn(), options)
    assert_received :stored
    assert conn.status == 202
    assert conn.halted
  end

  test "a storage failure returns 503, never an acknowledgement" do
    conn = WebhookPlug.call(conn(), options(persist: fn _ -> {:error, :database_down} end))
    assert conn.status == 503
  end

  test "unexpected persistence return values do not acknowledge" do
    conn = WebhookPlug.call(conn(), options(persist: fn _ -> {:ok, :not_the_contract} end))
    assert conn.status == 503
  end

  test "persistence exceptions propagate to the HTTP server as a failed request" do
    assert_raise RuntimeError, "database unavailable", fn ->
      WebhookPlug.call(conn(), options(persist: fn _ -> raise "database unavailable" end))
    end
  end

  test "invalid signature and invalid batch never call persistence" do
    opts = options(persist: fn _ -> flunk("must not persist") end)
    bad = String.replace(@raw, "1130", "1131")
    assert WebhookPlug.call(conn(bad), opts).status == 401
    payload = Jason.decode!(@raw)
    batch = put_in(payload, ["notificationItems"], payload["notificationItems"] ++ [%{}])
    assert WebhookPlug.call(conn(Jason.encode!(batch)), opts).status == 400
    assert WebhookPlug.call(conn("{broken"), opts).status == 400
    assert WebhookPlug.call(conn("{}"), opts).status == 400
  end

  test "the merchant allowlist is enforced after signature verification" do
    opts =
      options(
        merchant_accounts: ["AnotherMerchant"],
        persist: fn _ -> flunk("must not persist") end
      )

    assert WebhookPlug.call(conn(), opts).status == 403
  end

  test "reads every body chunk before signature verification" do
    <<a::binary-size(23), b::binary-size(151), c::binary>> = @raw
    conn = %{conn() | adapter: {ChunkAdapter, [a, b, c]}}
    assert WebhookPlug.call(conn, options()).status == 202
  end

  test "limits total body size, including when it arrives in chunks" do
    opts = options(max_body_bytes: 100, persist: fn _ -> flunk("must not persist") end)
    assert WebhookPlug.call(conn(), opts).status == 413
    chunks = [String.duplicate("a", 60), String.duplicate("b", 60)]
    conn = %{conn() | adapter: {ChunkAdapter, chunks}}
    assert WebhookPlug.call(conn, opts).status == 413
  end

  test "only handles configured path and POST" do
    other = Plug.Test.conn(:post, "/other", @raw)
    assert WebhookPlug.call(other, options()) == other
    assert WebhookPlug.call(Plug.Test.conn(:get, "/webhooks/adyen"), options()).status == 405
  end

  test "loads keys at request time so rotation does not require recompilation" do
    opts = options(hmac_keys: {__MODULE__, :rotating_keys, []})
    assert WebhookPlug.call(conn(), opts).status == 202
  end

  test "invalid runtime keys raise a sanitized configuration error instead of returning 401" do
    for keys <- [
          nil,
          [],
          "",
          "secret-not-hex",
          [@key, "secret-invalid"],
          {__MODULE__, :rotating_keys, []}
        ] do
      opts =
        options(
          hmac_keys: {__MODULE__, :configured_keys, [keys]},
          persist: fn _ -> flunk("must not persist") end
        )

      assert_raise ArgumentError, "invalid webhook option: resolved hmac_keys", fn ->
        WebhookPlug.call(conn(), opts)
      end
    end
  end

  test "valid runtime keys still distinguish forged signatures with 401" do
    opts =
      options(
        hmac_keys: {__MODULE__, :configured_keys, [[@key]]},
        persist: fn _ -> flunk("must not persist") end
      )

    assert WebhookPlug.call(conn(String.replace(@raw, "1130", "1131")), opts).status == 401
  end

  def configured_keys(keys), do: keys

  test "body read failures do not acknowledge" do
    conn = %{conn() | adapter: {ChunkAdapter, :failed}}

    assert WebhookPlug.call(conn, options(persist: fn _ -> flunk("must not persist") end)).status ==
             400
  end

  test "MFA persistence receives the verified batch before extra arguments" do
    opts = options(persist: {__MODULE__, :persist_batch, [self()]})
    assert WebhookPlug.call(conn(), opts).status == 202
    assert_received {:batch, [%{"eventCode" => "AUTHORISATION"}]}
  end

  def persist_batch(items, owner) do
    send(owner, {:batch, items})
    :ok
  end

  test "invalid configuration fails without exposing key values" do
    for override <- [
          [hmac_keys: []],
          [merchant_accounts: []],
          [persist: nil],
          [max_body_bytes: 0],
          [path: "relative"]
        ] do
      assert_raise ArgumentError, fn -> options(override) end
    end
  end

  def rotating_keys, do: [String.duplicate("ab", 32), @key]

  defp conn(raw \\ @raw), do: Plug.Test.conn(:post, "/webhooks/adyen", raw)

  defp options(overrides \\ []) do
    [
      path: "/webhooks/adyen",
      hmac_keys: [@key],
      merchant_accounts: ["TestMerchant"],
      persist: fn _ -> :ok end
    ]
    |> Keyword.merge(overrides)
    |> WebhookPlug.init()
  end
end
