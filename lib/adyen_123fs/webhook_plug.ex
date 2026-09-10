if Code.ensure_loaded?(Plug.Conn) do
  defmodule Adyen123FS.WebhookPlug do
    @moduledoc """
    Optional Plug for Standard webhooks. Mount **before `Plug.Parsers`**.

    Required options:
      * `:path` — exact webhook path, e.g. `/webhooks/adyen`.
      * `:hmac_keys` — hex key, non-empty key list, or `{module, function, args}`
        returning keys at request time (recommended for runtime secrets/rotation).
      * `:merchant_accounts` — non-empty allowlist checked against signed fields.
      * `:persist` — function of one argument or `{module, function, extra_args}`.
        Receives the full verified item list (first argument). Return **`:ok`
        only after a durable transaction has committed**. Duplicate delivery must
        also return `:ok` once it is safely known to be stored.

    Optional `:max_body_bytes` defaults to 1_000_000. Returns HTTP 202 only after
    persistence, 503 on non-`:ok` storage results, 401 for invalid signatures,
    403 for a merchant mismatch, 400 for malformed payloads, 413 for oversized
    bodies and 405 for other methods. Handler exceptions propagate so the HTTP
    server fails the request; they are never acknowledged. No business logic,
    in-memory deduplication or asynchronous fire-and-forget persistence is used.

    Header-signed non-standard webhooks require a separate endpoint using
    `Adyen123FS.Webhook.verify_body/3`; this Plug handles Standard webhooks only.
    """
    @behaviour Plug
    alias Adyen123FS.Webhook
    import Plug.Conn, only: [halt: 1, send_resp: 3]

    @impl true
    def init(options) do
      options =
        Keyword.validate!(options, [
          :path,
          :hmac_keys,
          :merchant_accounts,
          :persist,
          max_body_bytes: 1_000_000
        ])

      path = options[:path]
      unless is_binary(path) and String.starts_with?(path, "/"), do: invalid!("path")
      unless key_source?(options[:hmac_keys]), do: invalid!("hmac_keys")

      unless is_list(options[:merchant_accounts]) and options[:merchant_accounts] != [] and
               Enum.all?(options[:merchant_accounts], &(is_binary(&1) and &1 != "")),
             do: invalid!("merchant_accounts")

      unless callback?(options[:persist]), do: invalid!("persist")

      unless is_integer(options[:max_body_bytes]) and options[:max_body_bytes] > 0,
        do: invalid!("max_body_bytes")

      Map.new(options)
    end

    @impl true
    def call(conn, %{path: path}) when conn.request_path != path, do: conn

    def call(%{method: method} = conn, _) when method != "POST" do
      conn |> Plug.Conn.put_resp_header("allow", "POST") |> respond(405)
    end

    def call(conn, options) do
      case read_body(conn, options.max_body_bytes, 0, []) do
        {:ok, raw, conn} -> handle(conn, raw, options)
        {:error, status, conn} -> respond(conn, status)
      end
    end

    defp handle(conn, raw, options) do
      with {:ok, payload} <- Jason.decode(raw),
           {:ok, items} <-
             Webhook.verify_standard_request(payload, resolve_keys(options.hmac_keys)),
           true <- Enum.all?(items, &(&1["merchantAccountCode"] in options.merchant_accounts)) do
        case persist(options.persist, items) do
          :ok -> respond(conn, 202)
          _ -> respond(conn, 503)
        end
      else
        {:error, :invalid_signature} -> respond(conn, 401)
        false -> respond(conn, 403)
        _ -> respond(conn, 400)
      end
    end

    defp read_body(conn, limit, size, chunks) do
      case Plug.Conn.read_body(conn,
             length: min(limit - size + 1, 64_000),
             read_length: 64_000,
             read_timeout: 5_000
           ) do
        {state, chunk, conn} when state in [:ok, :more] ->
          new_size = size + byte_size(chunk)

          cond do
            new_size > limit ->
              {:error, 413, conn}

            state == :more ->
              read_body(conn, limit, new_size, [chunk | chunks])

            true ->
              {:ok, chunks |> then(&[chunk | &1]) |> Enum.reverse() |> IO.iodata_to_binary(),
               conn}
          end

        {:error, _} ->
          {:error, 400, conn}
      end
    end

    defp persist({module, function, args}, items), do: apply(module, function, [items | args])
    defp persist(function, items), do: function.(items)
    defp resolve_keys({module, function, args}), do: apply(module, function, args)
    defp resolve_keys(keys), do: keys
    defp key_source?({module, function, args}), do: mfa?(module, function, args)

    defp key_source?(keys) do
      keys = List.wrap(keys)

      keys != [] and
        Enum.all?(keys, fn key ->
          is_binary(key) and byte_size(key) == 64 and
            match?({:ok, _}, Base.decode16(key, case: :mixed))
        end)
    end

    defp callback?({module, function, args}), do: mfa?(module, function, args)
    defp callback?(function), do: is_function(function, 1)
    defp mfa?(module, function, args), do: is_atom(module) and is_atom(function) and is_list(args)
    defp invalid!(name), do: raise(ArgumentError, "invalid webhook option: #{name}")
    defp respond(conn, status), do: conn |> send_resp(status, "") |> halt()
  end
end
