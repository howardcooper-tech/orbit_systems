import 'package:orbit_point/data/destination_gateway.dart';
import 'package:orbit_point/data/destination_models.dart';
import 'package:orbit_point/data/gateway_exception.dart';
import 'package:orbit_point/integration/point_contract.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseDestinationGateway implements PointDestinationGateway {
  SupabaseDestinationGateway(this._client);

  final SupabaseClient _client;

  void _uuid(String value) {
    if (!PointContract.isUuid(value)) {
      throw const ValidationFailure('The id from navigation is not valid.');
    }
  }

  void _requireActingParent(String parentId) {
    _uuid(parentId);
    final actor = _client.auth.currentUser?.id;
    if (!PointContract.isActingParent(
      sessionUserId: actor,
      requestedParentId: parentId,
    )) {
      if (actor == null || actor.isEmpty) {
        throw const UnauthenticatedFailure();
      }
      throw const PermissionFailure(
        'This account cannot use another person\'s id.',
      );
    }
  }

  Future<dynamic> _rpc(String name, [Map<String, dynamic>? params]) async {
    try {
      return await _client.rpc(name, params: params);
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  Future<List<Map<String, dynamic>>> _select({
    required String table,
    required String columns,
    required Map<String, String> filters,
    String? or,
    String? order,
    bool descending = false,
    int? limit,
  }) async {
    try {
      dynamic query = _client.from(table).select(columns);
      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }
      if (or != null) query = query.or(or);
      if (order != null) query = query.order(order, ascending: !descending);
      if (limit != null) query = query.limit(limit);
      final rows = await query;
      return [
        for (final row in rows)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  GatewayException _mapPostgrest(PostgrestException error) {
    final message = error.message;
    switch (error.code) {
      case 'PGRST301':
      case 'PGRST303':
        return const UnauthenticatedFailure();
      case '42501':
        return PermissionFailure(safeServerMessage(message));
      case '22023':
        return ValidationFailure(safeServerMessage(message));
      default:
        if (message.contains('AUTH_REQUIRED') ||
            message.contains('POINT_GUARDIAN_REQUIRED') ||
            message.contains('CARETAKER_TRANSPORT_ACCESS_REQUIRED') ||
            message.contains(
              'ESTABLISHED_ORBIT_IDENTITY_CANNOT_SELF_ACTIVATE_NODE',
            )) {
          return PermissionFailure(safeServerMessage(message));
        }
        if (message.contains('INVALID_') ||
            message.contains('REQUIRED') ||
            message.contains('TOO_LONG') ||
            message.contains('WITHIN_90')) {
          return ValidationFailure(safeServerMessage(message));
        }
        return const NetworkFailure();
    }
  }

  @override
  Future<ParentRecord?> readParent(String parentId) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: DestinationContract.parents,
      columns: DestinationContract.parentColumns,
      filters: {'id': parentId},
    );
    if (rows.isEmpty) return null;
    final record = _parent(rows.first);
    if (record == null || record.id != parentId) return null;
    return record;
  }

  @override
  Future<ParentRecord> updateParentName({
    required String parentId,
    required String fullName,
  }) async {
    _requireActingParent(parentId);
    final trimmed = fullName.trim();
    if (trimmed.isEmpty || trimmed.length > 200) {
      throw const ValidationFailure('Enter a name of 200 characters or less.');
    }
    try {
      final row = await _client
          .from(DestinationContract.parents)
          .update({'full_name': trimmed})
          .eq('id', parentId)
          .select(DestinationContract.parentColumns)
          .maybeSingle();
      if (row == null) throw const PermissionFailure();
      final record = _parent(row);
      if (record == null ||
          record.id != parentId ||
          record.fullName != trimmed) {
        throw const NetworkFailure();
      }
      return record;
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  @override
  Future<List<SecondaryAuthorization>> listSecondaryAuthorizations(
    String parentId,
  ) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: DestinationContract.secondaryAuthorizations,
      columns: DestinationContract.secondaryColumns,
      filters: {'authorized_by_parent_id': parentId},
    );
    return [for (final row in rows) ?_secondary(row)];
  }

  @override
  Future<LanguagePreference> readLanguagePreference(String parentId) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: DestinationContract.guardianProfiles,
      columns: DestinationContract.guardianProfileColumns,
      filters: {'id': parentId},
    );
    if (rows.isEmpty) {
      return const LanguagePreference(stored: false, code: null);
    }
    final row = rows.first;
    if (row['id'] != parentId) {
      return const LanguagePreference(stored: false, code: null);
    }
    return LanguagePreference(
      stored: true,
      code: _languageCode(row['preferred_language']),
    );
  }

  @override
  Future<LanguagePreference> updateLanguagePreference({
    required String parentId,
    required String code,
  }) async {
    _requireActingParent(parentId);
    final normalized = code.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2}$').hasMatch(normalized)) {
      throw const ValidationFailure('Choose a two-letter language code.');
    }
    try {
      final row = await _client
          .from(DestinationContract.guardianProfiles)
          .update({'preferred_language': normalized})
          .eq('id', parentId)
          .select(DestinationContract.guardianProfileColumns)
          .maybeSingle();
      if (row == null || row['id'] != parentId) {
        return const LanguagePreference(stored: false, code: null);
      }
      final saved = _languageCode(row['preferred_language']);
      if (saved != normalized) throw const NetworkFailure();
      return LanguagePreference(stored: true, code: saved);
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  @override
  Future<SelfContact> readSelfContact(String parentId) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: DestinationContract.orbitUserProfiles,
      columns: DestinationContract.orbitUserPhoneColumns,
      filters: {'id': parentId},
    );
    if (rows.isEmpty || rows.first['id'] != parentId) {
      return const SelfContact(stored: false, phone: null);
    }
    return SelfContact(stored: true, phone: _phone(rows.first['phone_number']));
  }

  @override
  Future<SelfContact> updateSelfPhone({
    required String parentId,
    required String phone,
  }) async {
    _requireActingParent(parentId);
    final trimmed = phone.trim();
    if (!_validPhone(trimmed)) {
      throw const ValidationFailure(
        'Enter a telephone number of 32 characters or less.',
      );
    }
    try {
      final row = await _client
          .from(DestinationContract.orbitUserProfiles)
          .update({'phone_number': trimmed})
          .eq('id', parentId)
          .select(DestinationContract.orbitUserPhoneColumns)
          .maybeSingle();
      if (row == null || row['id'] != parentId) {
        return const SelfContact(stored: false, phone: null);
      }
      final saved = _phone(row['phone_number']);
      if (saved != trimmed) throw const NetworkFailure();
      return SelfContact(stored: true, phone: saved);
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  @override
  Future<SecondaryProfile?> readSecondaryProfile(String secondaryId) async {
    _uuid(secondaryId);
    final rows = await _select(
      table: DestinationContract.secondaryProfiles,
      columns: DestinationContract.secondaryProfileColumns,
      filters: {'id': secondaryId},
    );
    if (rows.isEmpty) return null;
    return _secondaryProfile(rows.first, secondaryId);
  }

  @override
  Future<List<FamilyInvitation>> listFamilyInvitations(String parentId) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: DestinationContract.familyInvitations,
      columns: DestinationContract.invitationColumns,
      filters: {'invited_by_parent_id': parentId},
    );
    return [for (final row in rows) ?_invitation(row, parentId)];
  }

  @override
  Future<FamilyInviteResult> requestFamilyInvite({
    required String parentId,
    required String email,
  }) async {
    _requireActingParent(parentId);
    final trimmed = email.trim();
    if (!_plausibleEmail(trimmed)) {
      return const FamilyInviteResult(
        outcome: FamilyInviteOutcome.rejected,
        message: DestinationContract.familyInviteRejected,
      );
    }
    return const FamilyInviteResult(
      outcome: FamilyInviteOutcome.unavailable,
      message: DestinationContract.familyInviteUnavailable,
    );
  }

  @override
  Future<List<CalendarEvent>> loadCalendar({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _rpc(DestinationContract.calendarRpc, {
      'p_from': _date(from),
      'p_to': _date(to),
    });
    return [for (final row in _rows(data)) ?_calendar(row)];
  }

  @override
  Future<String> exportCalendarEvent(String eventId) async {
    _uuid(eventId);
    try {
      final response = await _client.functions.invoke(
        DestinationContract.calendarExportFunction,
        method: HttpMethod.get,
        queryParameters: {'event_id': eventId},
      );
      final data = response.data;
      if (data is String && data.contains('BEGIN:VCALENDAR')) return data;
      throw const ValidationFailure(
        'Calendar export did not return a calendar file.',
      );
    } on FunctionsHttpException catch (error) {
      if (error.status == 401 || error.status == 403) {
        throw const UnauthenticatedFailure();
      }
      if (error.status == 404) {
        throw const ValidationFailure('Event not found.');
      }
      throw const NetworkFailure();
    } on FunctionsFetchException {
      throw const NetworkFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  @override
  Future<List<MemoMessage>> listMemos(String userId) async {
    _uuid(userId);
    final rows = await _select(
      table: DestinationContract.messages,
      columns: DestinationContract.messageColumns,
      filters: const {},
      or: 'recipient_id.eq.$userId,sender_id.eq.$userId',
      order: 'created_at',
      descending: true,
    );
    return [for (final row in rows) ?_memo(row, userId)];
  }

  @override
  Future<bool> markMemoRead({
    required String userId,
    required String messageId,
  }) async {
    _uuid(userId);
    _uuid(messageId);
    try {
      final row = await _client
          .from(DestinationContract.messages)
          .select('id,recipient_id,read_by_uuids')
          .eq('id', messageId)
          .eq('recipient_id', userId)
          .maybeSingle();
      if (row == null) return false;
      final current = _uuidList(row['read_by_uuids']);
      if (current.contains(userId)) return true;
      final updated = await _client
          .from(DestinationContract.messages)
          .update({
            'read_by_uuids': [...current, userId],
          })
          .eq('id', messageId)
          .eq('recipient_id', userId)
          .select('id,read_by_uuids');
      if (updated.isEmpty) return false;
      return _uuidList(updated.first['read_by_uuids']).contains(userId);
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  @override
  Future<List<NodeEntitlement>> myNodeMode() async {
    final data = await _rpc(DestinationContract.nodeModeRpc);
    return [for (final row in _rows(data)) ?_entitlement(row)];
  }

  @override
  Future<List<NodeDistrict>> listNodeDistricts() async {
    final data = await _rpc(DestinationContract.nodeDistrictsRpc);
    return [for (final row in _rows(data)) ?_district(row)];
  }

  @override
  Future<NodeActivationResult> requestNodeActivation({
    required String districtId,
    required String tripCode,
    required String gradeLabel,
    required String teacherName,
  }) async {
    _uuid(districtId);
    final data = await _rpc(DestinationContract.nodeActivationRpc, {
      'p_district_id': districtId,
      'p_trip_code': tripCode.trim(),
      'p_grade_label': gradeLabel.trim(),
      'p_teacher_name': teacherName.trim(),
    });
    final status = displayToken(asMap(data)?['status']) ?? '';
    return NodeActivationResult(
      status: status,
      message: status.isEmpty
          ? 'The server did not return an activation status.'
          : _activationMessage(status),
    );
  }

  @override
  Future<TransportCard> caretakerCard(String studentId) async {
    _uuid(studentId);
    final data = await _rpc(DestinationContract.caretakerCardRpc, {
      'p_student_id': studentId,
      'p_surface': 'POINT',
    });
    final assignments = asMap(data)?['assignments'];
    return TransportCard([
      for (final row in _rows(assignments)) ?_assignment(row),
    ]);
  }

  @override
  Future<List<DailyPlanRow>> dailyPlan({
    required String studentId,
    required DateTime serviceDate,
  }) async {
    _uuid(studentId);
    final data = await _rpc(DestinationContract.dailyPlanRpc, {
      'p_student_id': studentId,
      'p_service_date': _date(serviceDate),
    });
    final plans = asMap(data)?['plans'];
    return [for (final row in _rows(plans)) ?_plan(row, serviceDate)];
  }

  @override
  Future<List<TransportScheduleRow>> transportSchedules({
    required String studentId,
    required DateTime from,
    required DateTime to,
  }) async {
    _uuid(studentId);
    final data = await _rpc(DestinationContract.schedulesRpc, {
      'p_student_id': studentId,
      'p_from_date': _date(from),
      'p_to_date': _date(to),
    });
    final schedules = asMap(data)?['schedules'];
    return [for (final row in _rows(schedules)) ?_schedule(row)];
  }

  @override
  Future<void> setDailyMode({
    required String studentId,
    required DateTime serviceDate,
    required String servicePeriod,
    required String transportationMode,
    String? note,
  }) async {
    _uuid(studentId);
    await _rpc(DestinationContract.setDailyModeRpc, {
      'p_student_id': studentId,
      'p_service_date': _date(serviceDate),
      'p_service_period': servicePeriod,
      'p_transportation_mode': transportationMode,
      'p_note': _note(note),
    });
  }

  @override
  Future<void> cancelDailyMode({
    required String studentId,
    required DateTime serviceDate,
    required String servicePeriod,
  }) async {
    _uuid(studentId);
    await _rpc(DestinationContract.cancelDailyModeRpc, {
      'p_student_id': studentId,
      'p_service_date': _date(serviceDate),
      'p_service_period': servicePeriod,
    });
  }

  @override
  Future<void> setTransportSchedule({
    required String studentId,
    required DateTime startDate,
    required DateTime endDate,
    required String servicePeriod,
    required String transportationMode,
    required String recurrence,
    required List<int> weekdays,
    String? note,
  }) async {
    _uuid(studentId);
    await _rpc(DestinationContract.setScheduleRpc, {
      'p_student_id': studentId,
      'p_start_date': _date(startDate),
      'p_end_date': _date(endDate),
      'p_service_period': servicePeriod,
      'p_transportation_mode': transportationMode,
      'p_recurrence': recurrence,
      'p_selected_weekdays': weekdays,
      'p_note': _note(note),
    });
  }

  @override
  Future<void> cancelTransportSchedule(String scheduleId) async {
    _uuid(scheduleId);
    await _rpc(DestinationContract.cancelScheduleRpc, {
      'p_schedule_id': scheduleId,
    });
  }

  @override
  Future<List<BusChangeRequest>> listBusChanges(String studentId) async {
    _uuid(studentId);
    final rows = await _select(
      table: DestinationContract.busChanges,
      columns: DestinationContract.busChangeColumns,
      filters: {'student_id': studentId},
      order: 'created_at',
      descending: true,
    );
    return [for (final row in rows) ?_busChange(row)];
  }

  @override
  Future<void> decideBusChange({
    required String requestId,
    required bool approved,
    String? note,
  }) async {
    _uuid(requestId);
    await _rpc(DestinationContract.decideBusChangeRpc, {
      'p_request_id': requestId,
      'p_approved': approved,
      'p_note': _note(note),
    });
  }

  @override
  Future<List<PlanEventRow>> listPlanEvents(String studentId) async {
    _uuid(studentId);
    final rows = await _select(
      table: DestinationContract.planEvents,
      columns: DestinationContract.planEventColumns,
      filters: {'student_id': studentId},
      order: 'created_at',
      descending: true,
      limit: 8,
    );
    return [for (final row in rows) ?_planEvent(row)];
  }
}

String _date(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String? _note(String? note) {
  final trimmed = note?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

String _activationMessage(String status) {
  final known = safeServerMessage(status);
  if (known != 'The server rejected the request.') return known;
  return 'Server status: $status. No Node role was assigned on this device.';
}

Map<String, dynamic>? asMap(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  return null;
}

List<dynamic> _rows(dynamic data) {
  if (data is List) return data;
  return const [];
}

List<String> _uuidList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is String && PointContract.isUuid(item)) item,
  ];
}

ParentRecord? _parent(Map<String, dynamic> row) {
  final id = row['id'];
  if (id is! String || !PointContract.isUuid(id)) return null;
  final photo = displayToken(row['profile_photo_url']);
  return ParentRecord(
    id: id,
    fullName: displayToken(row['full_name']),
    nodeFlag: row['is_verified_node'] is bool
        ? row['is_verified_node'] as bool
        : null,
    verifiedAt: parseTimestamp(row['verified_at']),
    createdAt: parseTimestamp(row['created_at']),
    photoUrl: permittedProfilePhoto(photo) ? photo : null,
  );
}

SecondaryAuthorization? _secondary(Map<String, dynamic> row) {
  final studentId = row['student_id'];
  if (studentId is! String || !PointContract.isUuid(studentId)) return null;
  final id = row['id'];
  final secondaryId = row['secondary_id'];
  return SecondaryAuthorization(
    id: id is String && PointContract.isUuid(id) ? id : null,
    studentId: studentId,
    secondaryId: secondaryId is String && PointContract.isUuid(secondaryId)
        ? secondaryId
        : null,
    relationshipLabel: displayToken(row['relationship_label']) ?? '',
    morningTrack: row['morning_track_allowed'] == true,
    afternoonTrack: row['afternoon_track_allowed'] == true,
    chaperoneApproved: row['chaperone_approved_status'] == true,
  );
}

String? _languageCode(Object? value) {
  if (value is! String) return null;
  final code = value.trim().toLowerCase();
  if (!RegExp(r'^[a-z]{2}$').hasMatch(code)) return null;
  return code;
}

String? _phone(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (!_validPhone(trimmed)) return null;
  return trimmed;
}

bool _validPhone(String value) {
  if (value.isEmpty || value.length > 32) return false;
  return RegExp(r'^[0-9+().\-\s]+$').hasMatch(value);
}

bool _plausibleEmail(String value) {
  if (value.length < 3 || value.length > 200) return false;
  final at = value.indexOf('@');
  if (at <= 0 || at != value.lastIndexOf('@')) return false;
  final domain = value.substring(at + 1);
  return domain.contains('.') &&
      !domain.startsWith('.') &&
      !domain.endsWith('.');
}

SecondaryProfile? _secondaryProfile(
  Map<String, dynamic> row,
  String secondaryId,
) {
  if (row['id'] != secondaryId) return null;
  final first = displayToken(row['first_name']) ?? '';
  final last = displayToken(row['last_name']) ?? '';
  final name = '$first $last'.trim();
  return SecondaryProfile(id: secondaryId, displayName: name);
}

FamilyInvitation? _invitation(Map<String, dynamic> row, String parentId) {
  final id = row['id'];
  final studentId = row['student_id'];
  final invitedBy = row['invited_by_parent_id'];
  final status = row['status'];
  if (id is! String ||
      !PointContract.isUuid(id) ||
      studentId is! String ||
      !PointContract.isUuid(studentId) ||
      invitedBy != parentId ||
      status is! String) {
    return null;
  }
  if (row.containsKey('token_hash') || row.containsKey('invite_token')) {
    return null;
  }
  return FamilyInvitation(
    id: id,
    studentId: studentId,
    invitedByParentId: parentId,
    relationshipLabel: displayToken(row['relationship_label']) ?? '',
    status: status.trim(),
    expiresAt: parseTimestamp(row['expires_at']),
  );
}

CalendarEvent? _calendar(Map<String, dynamic> row) {
  final eventId = row['event_id'];
  final kind = row['event_kind'];
  final title = row['title'];
  final status = row['event_status'];
  final eventDate = parseDate(row['event_date']);
  if (eventId is! String ||
      !PointContract.isUuid(eventId) ||
      kind is! String ||
      title is! String ||
      status is! String ||
      eventDate == null) {
    return null;
  }
  final studentId = row['student_id'];
  return CalendarEvent(
    eventId: eventId,
    eventKind: kind,
    studentId: studentId is String && PointContract.isUuid(studentId)
        ? studentId
        : null,
    eventDate: eventDate,
    endDate: parseDate(row['end_date']) ?? eventDate,
    startsAt: parseTimestamp(row['starts_at']),
    endsAt: parseTimestamp(row['ends_at']),
    title: title.trim().isEmpty ? 'Not available' : title.trim(),
    eventStatus: status,
  );
}

MemoMessage? _memo(Map<String, dynamic> row, String userId) {
  final id = row['id'];
  if (id is! String || !PointContract.isUuid(id)) return null;
  final senderId = row['sender_id'];
  final body = row['message_body'];
  return MemoMessage(
    id: id,
    body: body is String && body.trim().isNotEmpty ? body.trim() : null,
    createdAt: parseTimestamp(row['created_at']),
    priority: row['priority_flag'] == true,
    read: _uuidList(row['read_by_uuids']).contains(userId),
    senderLabel: senderId == userId ? 'You' : 'Not available',
  );
}

NodeEntitlement? _entitlement(Map<String, dynamic> row) {
  final status = row['entitlement_status'];
  if (status is! String || status.trim().isEmpty) return null;
  return NodeEntitlement(
    tripCode: displayToken(row['trip_code']),
    destination: displayToken(row['destination']),
    status: status.trim(),
    validFrom: parseTimestamp(row['valid_from']),
    validUntil: parseTimestamp(row['valid_until']),
    organizationName: displayToken(row['organization_name']),
    profileName: displayToken(row['display_name']),
    identityVerified: row['identity_verified'] is bool
        ? row['identity_verified'] as bool
        : null,
    confidentialityAccepted: row['confidentiality_accepted'] is bool
        ? row['confidentiality_accepted'] as bool
        : null,
  );
}

NodeDistrict? _district(Map<String, dynamic> row) {
  final id = row['district_id'];
  final name = displayToken(row['district_name']);
  if (id is! String || !PointContract.isUuid(id) || name == null) return null;
  return NodeDistrict(id: id, name: name);
}

TransportAssignment? _assignment(Map<String, dynamic> row) {
  final driver = asMap(row['driver_card']);
  return TransportAssignment(
    servicePeriod: displayToken(row['service_period']),
    routeNumber: displayToken(row['route_number']),
    routeName: displayToken(row['route_name']),
    busNumber: displayToken(row['bus_number']),
    driverName: displayToken(driver?['name']),
    driverCode: displayToken(driver?['professional_id_code']),
    identityStatus: displayToken(row['identity_status']),
    isSubstitute: row['is_substitute'] == true,
    effectiveFrom: parseTimestamp(row['effective_from']),
    effectiveUntil: parseTimestamp(row['effective_until']),
  );
}

DailyPlanRow? _plan(Map<String, dynamic> row, DateTime serviceDate) {
  final planId = row['plan_id'];
  final period = row['service_period'];
  final mode = row['transportation_mode'];
  final status = row['status'];
  if (planId is! String ||
      !PointContract.isUuid(planId) ||
      period is! String ||
      mode is! String ||
      status is! String) {
    return null;
  }
  final note = row['note'];
  return DailyPlanRow(
    planId: planId,
    serviceDate: serviceDate,
    servicePeriod: period,
    transportationMode: mode,
    modeLabel: displayToken(row['mode_label']),
    status: status,
    note: note is String && note.trim().isNotEmpty ? note.trim() : null,
  );
}

TransportScheduleRow? _schedule(Map<String, dynamic> row) {
  final scheduleId = row['schedule_id'];
  final period = row['service_period'];
  final mode = row['transportation_mode'];
  final recurrence = row['recurrence'];
  final status = row['status'];
  if (scheduleId is! String ||
      !PointContract.isUuid(scheduleId) ||
      period is! String ||
      mode is! String ||
      recurrence is! String ||
      status is! String) {
    return null;
  }
  final note = row['note'];
  final weekdays = row['selected_weekdays'];
  return TransportScheduleRow(
    scheduleId: scheduleId,
    startDate: parseDate(row['start_date']),
    endDate: parseDate(row['end_date']),
    servicePeriod: period,
    transportationMode: mode,
    modeLabel: displayToken(row['mode_label']),
    recurrence: recurrence,
    weekdays: [
      for (final day in weekdays is List ? weekdays : const [])
        if (day is int) day else if (day is num) day.toInt(),
    ],
    status: status,
    note: note is String && note.trim().isNotEmpty ? note.trim() : null,
  );
}

BusChangeRequest? _busChange(Map<String, dynamic> row) {
  final id = row['id'];
  final status = row['status'];
  if (id is! String || !PointContract.isUuid(id) || status is! String) {
    return null;
  }
  final reason = row['reason'];
  return BusChangeRequest(
    id: id,
    status: status,
    servicePeriod: displayToken(row['service_period']),
    reason: reason is String && reason.trim().isNotEmpty ? reason.trim() : null,
    createdAt: parseTimestamp(row['created_at']),
    scope: displayToken(row['request_scope']),
  );
}

PlanEventRow? _planEvent(Map<String, dynamic> row) {
  final id = row['id'];
  final eventType = row['event_type'];
  if (id is! String || !PointContract.isUuid(id) || eventType is! String) {
    return null;
  }
  return PlanEventRow(
    id: id,
    eventType: eventType,
    transportationMode: displayToken(row['transportation_mode']),
    planStatus: displayToken(row['plan_status']),
    serviceDate: parseDate(row['service_date']),
    servicePeriod: displayToken(row['service_period']),
    createdAt: parseTimestamp(row['created_at']),
  );
}
