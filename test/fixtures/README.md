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
