/**
 * Orbit frontend binding contract.
 * Lovable (web) and FlutterFlow (mobile) consume these names only.
 * Clients: anon key + user JWT. Never service_role.
 *
 * Required JWT claim: tenant_id = districts.id
 * Issued by public.custom_access_token_hook (Phase 3e).
 * Duval Wall reads auth.jwt() ->> 'tenant_id' via jwt_tenant_id().
 */

export const ORBIT_RPC = {
  verifyStudentPin: "verify_student_pin",
  linkSisAccount: "link_sis_account",
  getMyRole: "get_my_role",
  getMyDistrict: "get_my_district",
  canActivateTransitMode: "can_activate_transit_mode",
  canAssistTransitMode: "can_assist_transit_mode",
  jwtTenantId: "jwt_tenant_id",
  /** Not created yet — do not bind Point "I'm here" until this ships. */
  parentZone1ImHere: "parent_zone1_im_here",
} as const;

export const ORBIT_TABLES = {
  trips: "trips",
  tripManifest: "trip_manifest",
  buses: "buses",
  students: "students",
  studentGuardians: "student_guardians",
  studentScanEvents: "student_scan_events",
  busTelemetryLogs: "bus_telemetry_logs",
  emergencyFlares: "emergency_flares",
  outboundAlerts: "outbound_alerts",
  transitTrips: "transit_trips",
  satelliteUnits: "satellite_units",
  transitSatelliteRoster: "transit_satellite_roster",
  auditWormLedger: "audit_worm_ledger",
  routeStops: "route_stops",
} as const;

export const ORBIT_EDGE = {
  telemetryIngress: "telemetry-ingress",
} as const;

export const LOVABLE_READS = [
  ORBIT_TABLES.trips,
  ORBIT_TABLES.tripManifest,
  ORBIT_TABLES.buses,
  ORBIT_TABLES.students,
  ORBIT_TABLES.emergencyFlares,
  ORBIT_TABLES.outboundAlerts,
  ORBIT_TABLES.auditWormLedger,
] as const;

export const PILOT_QUEUE_ONLY = {
  blePing: "capture.blePing → student_scan_events",
  offboard: "capture.offboard → student_scan_events",
} as const;

export const REALTIME_CHANNELS = {
  flares: "emergency_flares",
  manifest: "trip_manifest",
  scans: "student_scan_events",
} as const;
