# Orbit Systems — Consultant JSON Review

This folder is a curated review package for an external software consultant.

## Purpose
Review Orbit's JSON/API contracts and the code that receives, validates, transforms, and returns JSON. This is a review-only engagement. Do not deploy, run migrations, or connect this code to production.

## Primary review questions
- Are request and response objects consistent?
- Are field names, nesting, data types, required fields, and optional fields clear?
- Are null, missing, malformed, duplicate, and unexpected fields handled safely?
- Are error responses consistent and useful?
- Are timestamps, coordinates, IDs, and status values validated correctly?
- Does the transformation from inbound JSON to the database row preserve the intended meaning?
- Are there naming mismatches between request fields, transformed fields, and response fields?
- Are there edge cases that could make the frontend and backend disagree?

## Files
- `code/telemetry-ingress/index.ts` — current Supabase Edge Function handling bus telemetry JSON.
- `contracts/telemetry-request.json` — example valid inbound payload.
- `contracts/telemetry-success-response.json` — example successful response shape.
- `contracts/telemetry-error-response.json` — example validation error shape.
- `contracts/orbit-deploy-manifest.json` — Orbit's ordered JSON deployment manifest.
- `REVIEW-CHECKLIST.md` — suggested review format.

## Boundaries
- No credentials, passwords, access tokens, service-role keys, or real student/guardian data are included here.
- Environment-variable names may appear in source code, but not their values.
- Please document findings rather than changing production systems.
- If you suggest a change, include the file, field/property, current behavior, recommended behavior, and an example JSON payload.

## Suggested finding format
```
Severity: Low / Medium / High
File:
Field / property:
Issue:
Why it matters:
Example:
Recommended change:
```
