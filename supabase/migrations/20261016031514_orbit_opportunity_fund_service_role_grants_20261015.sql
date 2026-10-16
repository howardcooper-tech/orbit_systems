-- Grants only to the trusted server role; end users remain under RLS.
grant select,insert,update on public.orbit_calendar_provider_connections to service_role;
grant select,insert,update on public.orbit_trip_funding_rules to service_role;
grant select,insert,update on public.orbit_trip_assistance_requests to service_role;
grant select,insert on public.orbit_trip_donation_intents to service_role;
grant select,insert on public.orbit_trip_payment_ledger to service_role;
grant select,insert,update on public.orbit_trip_assistance_awards to service_role;
grant select,insert,update on public.orbit_trip_participation to service_role;
grant select,insert,update on public.orbit_calendar_events to service_role;