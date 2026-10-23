import 'package:orbit_point/data/gateway_exception.dart';
import 'package:orbit_point/data/point_models.dart';
import 'package:orbit_point/data/student_read_gateway.dart';
import 'package:orbit_point/integration/point_contract.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Anon-key reads only. Every guardian query filters `parent_id` to the
/// signed-in user. Rows that do not match the requested ids are discarded.
class SupabaseStudentReadGateway implements StudentReadGateway {
  SupabaseStudentReadGateway(this._client);

  final SupabaseClient _client;

  static List<String> get readPlan => PointContract.queriedTables;

  void _requireActingParent(String parentId) {
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

  @override
  Future<List<GuardianLink>> listGuardianLinks({
    required String parentId,
  }) async {
    _requireActingParent(parentId);
    final rows = await _select(
      table: PointContract.studentGuardians,
      columns: PointContract.guardianLinkColumns,
      filters: {'parent_id': parentId},
    );
    final links = <GuardianLink>[];
    for (final row in rows) {
      final link = _link(row, parentId: parentId);
      if (link != null) links.add(link);
    }
    return links;
  }

  @override
  Future<GuardianLink?> readGuardianLink({
    required String parentId,
    required String studentId,
  }) async {
    _requireActingParent(parentId);
    final row = await _maybe(
      table: PointContract.studentGuardians,
      columns: PointContract.guardianLinkColumns,
      filters: {'parent_id': parentId, 'student_id': studentId},
    );
    if (row == null) return null;
    return _link(row, parentId: parentId, studentId: studentId);
  }

  @override
  Future<StudentOpsRow?> readStudentOps(String studentId) async {
    final row = await _maybe(
      table: PointContract.students,
      columns: PointContract.studentOpsColumns,
      filters: {'id': studentId},
    );
    if (row == null) return null;
    final ops = StudentOpsRow.fromJson(row);
    if (ops.id != studentId) return null;
    return ops;
  }

  @override
  Future<SisIdentityRow?> readSisIdentity(String sisStudentId) async {
    final row = await _maybe(
      table: PointContract.studentSisEnrollment,
      columns: PointContract.sisColumns,
      filters: {'sis_student_id': sisStudentId},
    );
    if (row == null) return null;
    final sis = SisIdentityRow.fromJson(row);
    if (sis.sisStudentId != sisStudentId) return null;
    return sis;
  }

  Future<List<Map<String, dynamic>>> _select({
    required String table,
    required String columns,
    required Map<String, String> filters,
  }) async {
    try {
      var query = _client.from(table).select(columns);
      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }
      final rows = await query;
      return rows;
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on FormatException {
      throw const NetworkFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  Future<Map<String, dynamic>?> _maybe({
    required String table,
    required String columns,
    required Map<String, String> filters,
  }) async {
    try {
      var query = _client.from(table).select(columns);
      for (final entry in filters.entries) {
        query = query.eq(entry.key, entry.value);
      }
      return await query.maybeSingle();
    } on PostgrestException catch (error) {
      throw _mapPostgrest(error);
    } on AuthException {
      throw const UnauthenticatedFailure();
    } on FormatException {
      throw const NetworkFailure();
    } on GatewayException {
      rethrow;
    } catch (_) {
      throw const NetworkFailure();
    }
  }

  GuardianLink? _link(
    Map<String, dynamic> row, {
    required String parentId,
    String? studentId,
  }) {
    final link = GuardianLink.fromJson(row);
    if (link.parentId != parentId) return null;
    if (studentId != null && link.studentId != studentId) return null;
    return link;
  }

  GatewayException _mapPostgrest(PostgrestException error) {
    switch (error.code) {
      case '42501':
        return const PermissionFailure();
      case 'PGRST301':
      case 'PGRST303':
        return const UnauthenticatedFailure();
      default:
        return const NetworkFailure();
    }
  }
}
