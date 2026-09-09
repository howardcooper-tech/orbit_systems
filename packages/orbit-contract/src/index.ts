/**
 * Orbit frontend binding contract.
 * Lovable (web) and Flutter (field clients) consume these names only.
 * Clients: anon key + user JWT. Never service_role.
 *
 * Required JWT claim: tenant_id = districts.id
 * (Custom Access Token Hook or raw_app_meta_data surfaced as tenant_id).
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

export const BAY_RPC = {
  beginHubSession: "bay_begin_hub_session",
  endHubSession: "bay_end_hub_session",
  scheduleMaintenance: "bay_schedule_maintenance",
  downVehicle: "bay_down_vehicle",
  returnVehicleToService: "bay_return_vehicle_to_service",
  beginWorkSession: "bay_begin_work_session",
  replaceTablet: "bay_replace_tablet",
  touchWorkSession: "bay_touch_work_session",
  endWorkSession: "bay_end_work_session",
  claimWorkOrder: "bay_claim_work_order",
  assignWorkOrder: "bay_assign_work_order",
  releaseWorkOrder: "bay_release_work_order",
} as const;

export const BAY_TABLES = {
  tenantSettings: "bay_tenant_settings",
  staffAuthorizations: "bay_staff_authorizations",
  hubs: "bay_hubs",
  hubSessions: "bay_hub_sessions",
  workstations: "bay_workstations",
  workSessions: "bay_work_sessions",
  maintenanceSchedules: "bay_maintenance_schedules",
  vehicleServiceEvents: "bay_vehicle_service_events",
  workOrders: "maintenance_work_orders",
  workOrderNotes: "bay_work_order_notes",
  inspections: "bus_inspections",
  inspectionCheckpoints: "bay_inspection_checkpoints",
  inspectionMedia: "bay_inspection_media",
} as const;

export const BAY_STORAGE = {
  inspectionMediaBucket: "bay-inspection-media",
  maxObjectBytes: 20 * 1024 * 1024,
  acceptedMimeTypes: [
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
  ],
} as const;

export const BAY_CLIENTS = {
  hub: "Bay_Hub",
  workstation: "Bay_Workstation",
  tablet: "Bay_Tablet",
} as const;

export const BAY_INSPECTION_TYPES = [
  "Pre_Trip",
  "Mid_Trip",
  "Post_Trip",
] as const;

export const BAY_AUTH = {
  hubStepUpMaxAgeSeconds: 300,
  acceptedAmrMethods: ["password", "totp", "sso/saml"],
  copyAuthTokensBetweenDevices: false,
} as const;

export const BAY_REALTIME_CHANNELS = [
  BAY_TABLES.workOrders,
  BAY_TABLES.inspections,
  BAY_TABLES.hubSessions,
  BAY_TABLES.workSessions,
  BAY_TABLES.maintenanceSchedules,
  BAY_TABLES.vehicleServiceEvents,
  BAY_TABLES.workOrderNotes,
  BAY_TABLES.inspectionCheckpoints,
  BAY_TABLES.inspectionMedia,
] as const;
