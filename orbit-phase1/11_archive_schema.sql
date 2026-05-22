-- ORBIT PHASE 1 — 11: Cold storage schema (no jobs; Phase 3 adds archive functions)

BEGIN;

CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE archive.bus_telemetry_logs (LIKE public.bus_telemetry_logs INCLUDING ALL);
CREATE TABLE archive.audit_logs (LIKE public.audit_logs INCLUDING ALL);
CREATE TABLE archive.halo_manifest_snapshots (LIKE public.halo_manifest_snapshots INCLUDING ALL);
CREATE TABLE archive.comms_messages (LIKE public.comms_messages INCLUDING ALL);
CREATE TABLE archive.field_trip_checkouts (LIKE public.field_trip_checkouts INCLUDING ALL);

COMMIT;
