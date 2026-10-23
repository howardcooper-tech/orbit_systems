/// Guardian read contract for Point student details.
///
/// Proven from repo SQL. This is not a live staging session.
///
/// Identity: `parents.id` references `auth.users.id`
/// (`orbit-phase1/02_infrastructure.sql`). `student_guardians.parent_id`
/// therefore stores the signed-in user id. There is no `public.guardians`.
///
/// Guardian SELECT policies in `orbit-phase3/03_rls_duval_wall.sql`:
/// - `parent_view_own_students` on `students`
/// - `parent_view_sis_enrollment` on `student_sis_enrollment`
///
/// `student_guardians` is tenant-walled (`orbit-phase3/08_phase_3c_duval_wall.sql`)
/// and that RLS file does not add a permissive parent SELECT policy. The
/// client still filters `parent_id` to the signed-in user and does not fall
/// back to an unscoped `students` list. Staff policies on `students` are not
/// a guardian list.
///
/// Not queried, because no guardian SELECT policy or column exists:
/// schools, buses, routes, route_stops, trips (no `route_id`), trip_manifest,
/// student_scan_events, staff_profiles, student_secondary_authorizations.
/// Grade, student photo, AM/PM routes, stop times, driver display, and
/// substitution notices are unavailable for the same reason.
///
/// Medical, PIN, date of birth, GPS, status notes, and fob hashes are never
/// selected.
abstract final class PointContract {
  static const stagingRef = 'ydlwukjzqtssbzirnefs';
  static const productionRef = 'fovtqoonhblwdsiranse';
  static const appVersionLabel = 'Orbit Point 1.0.0+1';

  /// Release screens keep the version. The project ref is debug-only.
  static String settingsAbout({required bool includeEnvironment}) {
    if (!includeEnvironment) return appVersionLabel;
    return '$appVersionLabel\nStaging project $stagingRef';
  }

  /// A client-supplied parent id is usable only when it is the signed-in user.
  static bool isActingParent({
    required String? sessionUserId,
    required String requestedParentId,
  }) {
    return sessionUserId != null &&
        sessionUserId == requestedParentId &&
        isUuid(sessionUserId);
  }

  static const students = 'students';
  static const studentGuardians = 'student_guardians';
  static const studentSisEnrollment = 'student_sis_enrollment';

  static const guardianLinkColumns = 'student_id,parent_id,relationship';
  static const studentOpsColumns =
      'id,sis_student_id,school_id,current_status,missing_status,current_bus_id,archived_at';
  static const sisColumns =
      'sis_student_id,full_name,enrollment_status,school_id,archived_at';

  static const queriedTables = <String>[
    studentGuardians,
    students,
    studentSisEnrollment,
  ];

  static const forbiddenColumns = <String>[
    'medical_alert_flag',
    'medical_notes',
    'date_of_birth',
    'pin_hash',
    'pin_updated_at',
    'status_note',
    'assigned_stop_point',
    'last_known_gps',
    'hardware_fob_uid_hash',
    'hardware_fob_key_version',
    'profile_photo_url',
    'headshot_url',
    'requires_adult_release',
  ];

  static const photoUnavailable =
      'No student photo is available. Parent photos are not shown.';
  static const gradeUnavailable =
      'Grade is not available. No grade column exists for this view.';
  static const schoolUnavailable =
      'School name is not available to this guardian view.';
  static const routeUnavailable =
      'Route number is not available. Trips have no route id for this view.';
  static const busNumberUnavailable =
      'Bus number is not available to this guardian view.';
  static const noCurrentBus = 'No current bus';
  static const statusWithheld = 'Status withheld';
  static const statusUnavailable = 'Transportation status is not available.';
  static const assignmentUnavailable =
      'Transportation assignment is not available to this guardian view.';
  static const amPmUnavailable =
      'AM and PM routes are not available to this guardian view.';
  static const stopUnavailable =
      'Pickup and dropoff stops and times are not available to this guardian view.';
  static const driverUnavailable =
      'Driver details are not available to this guardian view.';
  static const substitutionUnavailable =
      'Substitution notices are not available to this guardian view.';
  static const activityUnavailable =
      'Boarding, exit, and status history are not available to this guardian view.';
  static const activityEmpty =
      'No boarding or exit events are available for this student.';
  static const nameUnavailable = 'Name was not returned for this guardian.';
  static const enrollmentUnavailable =
      'Enrollment was not returned for this guardian.';
  static const relationshipUnavailable =
      'Relationship was not returned for this guardian.';
  static const calendarUnavailable = 'Calendar is not available in this app.';
  static const rideRequestUnavailable =
      'Ride-request scheduling is not available. This screen does not create requests.';
  static const authorizedAdultsUnavailable =
      'Authorized adults are not available to this guardian view.';
  static const homeEmptyMessage =
      'No linked students are visible for this guardian. '
      'Orbit will not show sample students. An empty result can also mean '
      'the guardian link is not readable under current policies.';
  static const detailsEmptyMessage =
      'No student was selected. Open a student from Point Home.';
  static const permissionDeniedMessage =
      'This student is not visible to the signed-in guardian. '
      'No matching guardian link was returned, so no profile is shown.';
  static const loadErrorMessage = 'The student record could not be loaded.';
  static const invalidIdMessage =
      'The student id from navigation is not valid.';
  static const homeLoadErrorMessage = 'Linked students could not be loaded.';
  static const homePermissionMessage =
      'Sign in as the guardian to view linked students.';

  static final RegExp uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static bool isUuid(String value) => uuidPattern.hasMatch(value);

  static List<String> get selectedColumns => <String>[
    ...guardianLinkColumns.split(','),
    ...studentOpsColumns.split(','),
    ...sisColumns.split(','),
  ];
}
