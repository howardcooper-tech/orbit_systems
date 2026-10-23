import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_point/config/supabase_env.dart';
import 'package:orbit_point/integration/point_contract.dart';

void main() {
  test('staging anon configuration is the only allowed target', () {
    expect(
      const SupabaseEnv(
        url: 'https://ydlwukjzqtssbzirnefs.supabase.co',
        anonKey: 'anon-key',
      ).isAllowed,
      isTrue,
    );
    expect(
      const SupabaseEnv(
        url: 'https://fovtqoonhblwdsiranse.supabase.co',
        anonKey: 'anon-key',
      ).blockReason,
      contains('Production'),
    );
    expect(
      const SupabaseEnv(
        url: 'https://ydlwukjzqtssbzirnefs.supabase.co',
        anonKey: '',
      ).isAllowed,
      isFalse,
    );
    final serviceRole = const SupabaseEnv(
      url: 'https://ydlwukjzqtssbzirnefs.supabase.co',
      anonKey: 'header.service_role.signature',
    );
    expect(serviceRole.isAllowed, isFalse);
    expect(serviceRole.blockReason, isNot(contains('signature')));
  });

  test('release settings omit the staging project reference', () {
    final release = PointContract.settingsAbout(includeEnvironment: false);
    final debug = PointContract.settingsAbout(includeEnvironment: true);
    expect(release, 'Orbit Point 1.0.0+1');
    expect(release, isNot(contains(PointContract.stagingRef)));
    expect(release, isNot(contains('Staging')));
    expect(debug, contains(PointContract.stagingRef));
  });

  test('a parent id is accepted only for the signed-in user', () {
    const actor = '11111111-1111-4111-8111-111111111111';
    const other = '22222222-2222-4222-8222-222222222222';
    expect(
      PointContract.isActingParent(
        sessionUserId: actor,
        requestedParentId: actor,
      ),
      isTrue,
    );
    expect(
      PointContract.isActingParent(
        sessionUserId: actor,
        requestedParentId: other,
      ),
      isFalse,
    );
    expect(
      PointContract.isActingParent(
        sessionUserId: null,
        requestedParentId: actor,
      ),
      isFalse,
    );
  });

  test('selected columns exclude medical, pin, photo, and gps fields', () {
    final selected = PointContract.selectedColumns.toSet();
    for (final column in PointContract.forbiddenColumns) {
      expect(selected, isNot(contains(column)));
    }
    expect(PointContract.queriedTables, isNot(contains('student_scan_events')));
    expect(PointContract.queriedTables, isNot(contains('buses')));
    expect(PointContract.queriedTables, isNot(contains('schools')));
    expect(PointContract.queriedTables, isNot(contains('staff_profiles')));
  });
}
