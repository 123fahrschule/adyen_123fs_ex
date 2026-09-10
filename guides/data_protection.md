# Payment-scoped erasure at Adyen

Data Protection is a separate Adyen service. Construct a dedicated client; a
Checkout client is rejected locally, and Checkout functions reject this client.

```elixir
client = Adyen123FS.Client.new(
  service: :data_protection,
  environment: :test,
  api_key: System.fetch_env!("ADYEN_DATA_PROTECTION_API_KEY")
)

Adyen123FS.DataProtection.request_subject_erasure(client, %{
  "merchantAccount" => merchant_account,
  "pspReference" => original_payment_psp_reference
})
```

The default version is 1. Test uses
`https://ca-test.adyen.com/ca/services/DataProtectionService/v1`; live uses
`https://ca-live.adyen.com/ca/services/DataProtectionService/v1`. Neither host
has a Checkout company prefix. Supplying `live_prefix` raises a configuration
error rather than silently ignoring it. Keep the API key in runtime secrets.

Adyen's documentation requires `merchantAccount` and `pspReference`, although the
pinned OpenAPI schema marks no properties required. The client follows the
documentation and requires both as non-empty strings. The PSP reference is the
original payment authorisation: one request targets that payment's shopper data,
not every payment associated with a shopper. Account and payment selection must
come from your verified internal records.

## Inspect the result, including after HTTP 200

| result | Meaning and application handling |
| --- | --- |
| `SUCCESS` | Accepted for asynchronous processing. Record acceptance; do not mark deletion complete solely on this response. |
| `ACTIVE_RECURRING_TOKEN_EXISTS` | An active recurring token prevents deletion. Resolve the recurring relationship explicitly before another request. |
| `PAYMENT_NOT_FOUND` | Investigate the account/reference mapping; do not treat it as confirmed deletion. |
| `ALREADY_PROCESSED` | Adyen already received a request for this payment. This does not establish whether asynchronous erasure has finished. |
| Any future value | Preserve it and investigate; never invent a successful result. |

Responses stay string-keyed maps; no result is converted into an atom. There is
no declared idempotency-key support for this service. The client rejects that
option, makes one attempt and marks transport/API errors non-retryable, including
an HTTP response with `transient-error: true`. An intentional manual repeat for
the identical target can return `ALREADY_PROCESSED`; reconcile uncertain results
before deciding to repeat. Never retry automatically with a different target or
with `forceErasure` added.

## Recurring payments and forceErasure

`forceErasure` is passed through only when you supply it. It is never defaulted.
It can delete this payment's shopper data even with an active recurring
relationship, but it does **not** cancel the recurring transaction.

Prefer stopping future charges in your application and disabling the stored
payment method with `Checkout.delete_stored_payment_method/3`, using a separate
Checkout client and the correct merchant/shopper/token mapping, before submitting
erasure. An explicit decision to use `forceErasure: true` must account for the
still-active recurring relationship; it is not an automatic fallback.

## Include the application's records in the deletion process

Adyen erasure only covers Adyen's data for the target payment. Your webhook inbox,
outbox, accounting ledger, logs, backups and exports can retain merchantReference,
amounts, PSP references and other shopper data. This SDK does not delete them.

Use a coordinated process:

1. Identify all relevant payments and your own records. Review applicable
   retention duties, including tax/accounting retention, deletion obligations
   and any legal holds under your organisation's retention policy.
2. Resolve active recurring relationships, then request Adyen-side erasure and
   record the result. Adyen processes accepted requests asynchronously and under
   the Merchant Agreement. Its Customer Area exposes redacted shopper fields
   and the redaction date for verification.
3. Delete, anonymise or retain your own records according to the approved policy.
   Keep only the permitted evidence needed to track outstanding requests and
   reconcile retained financial records. Include backup and export retention.

An API response does not settle your legal retention policy or prove that every
copy in your organisation has been erased. No RegistrationService or Charger
deletion workflow is implemented by this library.

Sources: [Adyen Data Protection API](https://docs.adyen.com/development-resources/data-protection-api/),
[pinned v1 OpenAPI](https://github.com/Adyen/adyen-openapi/blob/f82d1fe674e536cc2c6b0d7946e0e827873a4fbf/json/DataProtectionService-v1.json).
