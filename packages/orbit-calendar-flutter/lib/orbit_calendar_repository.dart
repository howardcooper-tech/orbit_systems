import 'package:supabase_flutter/supabase_flutter.dart';

/// Orbit Calendar staging adapter. Wire into Point, Pin and Satellite UI.
/// Uses current Supabase session and tenant-scoped, invoker-rights RPCs.
class OrbitCalendarRepository {
  OrbitCalendarRepository(this.supabase);
  final SupabaseClient supabase;

  Future<List<Map<String, dynamic>>> pointAndPin({
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase.rpc('orbit_my_calendar', params: {
      'p_from': _ymd(from),
      'p_to': _ymd(to),
    });
    return _rows(result);
  }

  Future<List<Map<String, dynamic>>> satellite({
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase.rpc('orbit_satellite_calendar', params: {
      'p_from': _ymd(from),
      'p_to': _ymd(to),
    });
    return _rows(result);
  }

  /// Only Central/authorized staff can insert a school-wide event.
  /// Field-trip events are generated from Orbit Field trip records.
  Future<void> createSchoolEvent({
    required String tenantId,
    required String schoolId,
    required String title,
    required DateTime day,
  }) async {
    await supabase.from('orbit_calendar_events').insert({
      'tenant_id': tenantId,
      'school_id': schoolId,
      'event_type': 'school_event',
      'title': title,
      'event_date': _ymd(day),
      'status': 'draft',
    });
  }

  /// Point's permission slip MUST continue using the existing separate
  /// point_submit_field_trip_permission RPC, not these financial methods.
  Future<void> requestConfidentialTripAssistance({
    required String tenantId,
    required String tripId,
    required String studentId,
  }) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) throw StateError('Sign in to request assistance.');
    await supabase.from('orbit_trip_assistance_requests').insert({
      'tenant_id': tenantId,
      'trip_id': tripId,
      'student_id': studentId,
      'requested_by': userId,
    });
  }

  /// A donation *intent* is not a charge, a paid receipt or a tax receipt.
  /// Do not display a payment confirmation until verified checkout is live.
  Future<void> expressDonationIntent({
    required String tenantId,
    required String tripId,
    required int amountCents,
  }) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) throw StateError('Sign in to donate.');
    if (amountCents < 100 || amountCents > 1000000) {
      throw ArgumentError.value(amountCents, 'amountCents');
    }
    await supabase.from('orbit_trip_donation_intents').insert({
      'tenant_id': tenantId,
      'trip_id': tripId,
      'amount_cents': amountCents,
      'donor_user_id': userId,
    });
  }

  Future<Map<String, dynamic>?> fundingRules(String tripId) async {
    return await supabase.from('orbit_trip_funding_rules')
        .select('trip_id,cost_cents,currency,contribution_deadline,assistance_deadline,'
            'capacity,donations_enabled,assistance_enabled,checkout_enabled')
        .eq('trip_id', tripId).maybeSingle();
  }

  Future<List<Map<String, dynamic>>> participation(String tripId) async {
    return _rows(await supabase.from('orbit_trip_participation')
        .select('student_id,status,selection_method,decided_at')
        .eq('trip_id', tripId));
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static List<Map<String, dynamic>> _rows(dynamic rows) =>
      (rows as List).map((item) => Map<String, dynamic>.from(item as Map)).toList();
}
