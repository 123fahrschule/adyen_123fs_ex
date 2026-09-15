defmodule Adyen123FS.DataProtection do
  @moduledoc """
  Adyen Data Protection API v1 for payment-scoped subject erasure requests.

  Build a separate client with `Adyen123FS.Client.new(service: :data_protection,
  api_key: key)`. Checkout clients are rejected locally. This API acts on Adyen's
  data, not the consuming application's inbox, ledger or retained records.
  """
  alias Adyen123FS.{Client, Error}

  @doc """
  POST `/requestSubjectErasure`. Requires merchantAccount and pspReference, as
  documented by Adyen even though its OpenAPI lists no required properties.
  Additional fields are forwarded unchanged. `forceErasure` is never defaulted:
  setting it explicitly can erase this payment's shopper data while leaving an
  existing recurring transaction active. Prefer disabling the stored method first.

  HTTP 200 is not confirmation of deletion. Inspect the response's string result:
  * SUCCESS: accepted for asynchronous processing, not yet confirmed deleted.
  * ACTIVE_RECURRING_TOKEN_EXISTS: an active recurring token prevents erasure.
  * PAYMENT_NOT_FOUND: the payment reference was not found.
  * ALREADY_PROCESSED: Adyen already received a request for this payment reference.
  Unknown future results are preserved and require investigation.

  There is no declared idempotency-key support: the option is rejected and no
  error is marked automatically retryable. An intentional manual repeat for the
  identical payment can return ALREADY_PROCESSED. Do not automatically retry an
  uncertain result or silently add forceErasure. This operation has no declared
  query parameters or supported request options. Omit the options argument or
  pass `[]`; any other value returns a validation error before network access.
  """
  @spec request_subject_erasure(Client.t(), map(), keyword()) :: Client.result()
  def request_subject_erasure(client, body, options \\ []) do
    with :ok <- Client.ensure_service(client, :data_protection),
         :ok <- validate(body),
         :ok <- validate_options(options) do
      Client.request(client, :post, "/requestSubjectErasure", body, options)
    end
  end

  defp validate(body) when is_map(body) do
    valid =
      Enum.all?(Map.keys(body), &is_binary/1) and
        Enum.all?(["merchantAccount", "pspReference"], fn field ->
          value = Map.get(body, field)
          is_binary(value) and String.trim(value) != ""
        end)

    if valid,
      do: :ok,
      else: invalid("use Adyen string keys and non-empty merchantAccount and pspReference")
  end

  defp validate(_), do: invalid("body must be a map")
  defp validate_options([]), do: :ok
  defp validate_options(_), do: invalid("request_subject_erasure does not accept options")

  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}
end
