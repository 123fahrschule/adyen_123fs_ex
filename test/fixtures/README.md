# Fixture provenance

`standard_webhook.json` contains the public example from Adyen's
[HMAC verification guide](https://docs.adyen.com/development-resources/webhooks/secure-webhooks/verify-hmac-signatures/).
Its public demonstration key is in the test. These are not account credentials.

The UTF-8/separator and raw-body expected signatures were calculated independently
with Python's `hmac` and `hashlib.sha256`, using the same public example key.
Standard canonicalization is also checked against the
[official Node SDK](https://github.com/Adyen/adyen-node-api-library/blob/main/src/utils/hmacValidator.ts).
Standard NotificationRequestItem values are colon-joined without the legacy HPP
key/value escaping. Header-signed events use the exact original raw body.

Sources checked 2026-09-10. No test calculates its expected signature using the
implementation under test.

`checkout_v72_contract.json` is an extracted contract from Adyen's official
CheckoutService-v72 OpenAPI specification, pinned to the source revision and
SHA-256 recorded in the fixture. It includes HTTP methods, routes, required body
fields/types and required query parameters. It is not generated from this SDK.
`api_contract_test.exs` invokes all 16 public endpoint functions against it.

When upgrading the API version, retrieve the official specification at a pinned
revision, re-extract the supported operations, and inspect the diff. Keep test
fixtures offline and deterministic. These contract tests check routing and
required shapes; they do not replace Adyen's full conditional schema validation
or sandbox acceptance testing for your merchant account.
