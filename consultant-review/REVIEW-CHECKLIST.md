# JSON/API Review Checklist

Use this checklist while reviewing the included contracts and Edge Function.

- [ ] Required fields are clearly enforced.
- [ ] Optional fields have predictable defaults.
- [ ] Unknown extra fields do not create unsafe behavior.
- [ ] Numeric strings vs numeric values are handled intentionally.
- [ ] Empty strings, nulls, and missing properties are handled.
- [ ] IDs are validated enough for the downstream database operation.
- [ ] Latitude/longitude ordering is consistent everywhere.
- [ ] Timestamps are parsed and normalized consistently.
- [ ] Success and error responses use consistent JSON shapes.
- [ ] HTTP status codes match the JSON response meaning.
- [ ] Database-row property names match the expected storage contract.
- [ ] Returned JSON does not expose internal errors or secrets.
- [ ] Malformed JSON produces a controlled response.
- [ ] Method restrictions are enforced.
- [ ] Duplicate/replayed requests are considered where relevant.
- [ ] Race-condition or retry behavior is considered where relevant.
- [ ] Frontend-facing field names are stable and documented.

For every issue found, provide a minimal JSON example that reproduces the problem when possible.
