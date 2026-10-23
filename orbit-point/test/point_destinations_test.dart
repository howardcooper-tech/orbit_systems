import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_point/data/destination_models.dart';
import 'package:orbit_point/data/point_models.dart';
import 'package:orbit_point/integration/point_contract.dart';
import 'package:orbit_point/navigation/point_routes.dart';
import 'package:orbit_point/orbit_scope.dart';
import 'package:orbit_point/pages/point_bus_route_page.dart';
import 'package:orbit_point/pages/point_calendar_page.dart';
import 'package:orbit_point/pages/point_memos_page.dart';
import 'package:orbit_point/pages/point_node_entry_page.dart';
import 'package:orbit_point/pages/point_profile_page.dart';
import 'package:orbit_point/pages/point_ride_options_page.dart';
import 'package:orbit_point/pages/point_settings_page.dart';
import 'package:orbit_point/state/auth_controller.dart';
import 'package:orbit_point/state/profile_controller.dart';
import 'package:orbit_point/state/ride_options_controller.dart';
import 'package:orbit_point/state/student_details_controller.dart';
import 'package:orbit_point/theme/orbit_theme.dart';

import 'support/scripted_destination_gateway.dart';
import 'support/scripted_gateways.dart';

void main() {
  const studentId = '11111111-1111-4111-8111-111111111111';
  const parentId = '22222222-2222-4222-8222-222222222222';
  const districtId = '33333333-3333-4333-8333-333333333333';

  Future<void> pumpScoped(
    WidgetTester tester, {
    required Widget page,
    required FixedSession session,
    required ScriptedStudentReadGateway students,
    required ScriptedDestinationGateway destinations,
    Object? arguments,
  }) async {
    final auth = AuthController(session);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOrbitTheme(),
        builder: (context, child) {
          return OrbitScope(
            session: session,
            students: students,
            destinations: destinations,
            auth: auth,
            child: child ?? const SizedBox.shrink(),
          );
        },
        onGenerateRoute: (settings) {
          return MaterialPageRoute<void>(
            settings: RouteSettings(name: settings.name, arguments: arguments),
            builder: (_) => page,
          );
        },
        initialRoute: '/',
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  test('profile uses the session guardian email and name edit', () async {
    final destinations = ScriptedDestinationGateway(
      parent: const ParentRecord(
        id: parentId,
        fullName: 'Ada Guardian',
        nodeFlag: false,
        verifiedAt: null,
        createdAt: null,
      ),
    );
    final session = FixedSession(
      parentId,
      email: 'guardian@example.com',
      emailVerified: true,
    );
    final controller = ProfileController(
      destinations: destinations,
      students: ScriptedStudentReadGateway(),
      session: session,
    );
    await controller.load();
    expect(controller.state.email, 'guardian@example.com');
    expect(controller.state.emailVerified, isTrue);
    expect(controller.state.record?.fullName, 'Ada Guardian');
    final saved = await controller.saveName('Ada Updated');
    expect(saved, isTrue);
    expect(destinations.lastUpdatedName, 'Ada Updated');
    expect(destinations.authorizationWrites, 0);
    expect(destinations.roleWrites, 0);
    controller.dispose();
  });

  test('invalid ride id does not query the destination gateway', () async {
    final destinations = ScriptedDestinationGateway();
    final students = ScriptedStudentReadGateway();
    final controller = RideOptionsController(
      destinations: destinations,
      students: students,
      session: FixedSession(parentId),
    );
    await controller.load('not-a-student');
    expect(controller.state.message, PointContract.invalidIdMessage);
    expect(destinations.queriedIds, isEmpty);
    expect(students.guardianLinkReads, 0);
    controller.dispose();
  });

  test(
    'missing student id does not query student or transport reads',
    () async {
      final destinations = ScriptedDestinationGateway();
      final students = ScriptedStudentReadGateway();
      final details = StudentDetailsController(
        students: students,
        session: FixedSession(parentId),
        destinations: destinations,
      );
      await details.load(null);
      expect(details.state.phase, StudentDetailsPhase.empty);
      expect(students.guardianLinkReads, 0);
      expect(destinations.transportCalls, 0);
      details.dispose();
    },
  );

  test('caretaker card fills bus and route without showing a uuid', () async {
    final destinations = ScriptedDestinationGateway(
      card: const TransportCard([
        TransportAssignment(
          servicePeriod: 'AM',
          routeNumber: '12',
          routeName: 'North',
          busNumber: '104',
          driverName: 'Pat Driver',
          driverCode: 'D-1',
          identityStatus: 'VERIFIED',
          isSubstitute: false,
          effectiveFrom: null,
          effectiveUntil: null,
        ),
      ]),
    );
    final students = ScriptedStudentReadGateway(
      link: const GuardianLink(
        studentId: studentId,
        parentId: parentId,
        relationship: 'Guardian',
      ),
      ops: const StudentOpsRow(
        id: studentId,
        sisStudentId: 'SIS-1',
        currentStatus: 'off_bus',
        missingStatus: 'NONE',
        hasCurrentBus: false,
        isArchived: false,
      ),
      sis: const SisIdentityRow(
        sisStudentId: 'SIS-1',
        fullName: 'Enrolled Name',
        enrollmentStatus: 'active',
        isArchived: false,
      ),
    );
    final controller = StudentDetailsController(
      students: students,
      session: FixedSession(parentId),
      destinations: destinations,
    );
    await controller.load(studentId);
    expect(controller.state.snapshot?.busNumber.value, '104');
    expect(controller.state.snapshot?.routeNumber.value, '12 · North');
    expect(destinations.transportCalls, 1);
    controller.dispose();
  });

  testWidgets('calendar renders an empty month without a fake event', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway();
    await pumpScoped(
      tester,
      page: const PointCalendarPage(),
      session: FixedSession(parentId),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
    );
    expect(
      find.text('No calendar events were returned for this month.'),
      findsOneWidget,
    );
    expect(find.text('Spring concert'), findsNothing);
    expect(destinations.calendarCalls, 1);
    expect(destinations.exportCalls, 0);
  });

  testWidgets('memos stay empty when no rows are returned', (tester) async {
    final destinations = ScriptedDestinationGateway();
    await pumpScoped(
      tester,
      page: const PointMemosPage(),
      session: FixedSession(parentId),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
    );
    expect(find.text('No messages were returned.'), findsOneWidget);
    expect(find.text('School will dismiss early'), findsNothing);
    expect(destinations.memoCalls, 1);
  });

  testWidgets('node entry does not write a role', (tester) async {
    final destinations = ScriptedDestinationGateway(
      districts: const [NodeDistrict(id: districtId, name: 'Listed District')],
    );
    await pumpScoped(
      tester,
      page: const PointNodeEntryPage(),
      session: FixedSession(parentId),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
    );
    await tester.enterText(find.widgetWithText(TextField, 'Trip code'), 'TRIP');
    await tester.enterText(find.widgetWithText(TextField, 'Grade'), '4');
    await tester.enterText(
      find.widgetWithText(TextField, 'Teacher name'),
      'Lee',
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listed District').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('node-submit')));
    await tester.pumpAndSettle();
    expect(destinations.activationCalls, 1);
    expect(destinations.roleWrites, 0);
    expect(find.textContaining('did not assign a role'), findsOneWidget);
    expect(find.textContaining('You are now'), findsNothing);
  });

  testWidgets('settings sign-out calls the existing session sign-out', (
    tester,
  ) async {
    final session = FixedSession(parentId, email: 'guardian@example.com');
    await pumpScoped(
      tester,
      page: const PointSettingsPage(),
      session: session,
      students: ScriptedStudentReadGateway(),
      destinations: ScriptedDestinationGateway(),
    );
    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();
    expect(session.signOutCalls, 1);
    expect(session.userId, isNull);
  });

  testWidgets('release settings hide the staging project reference', (
    tester,
  ) async {
    await pumpScoped(
      tester,
      page: const PointSettingsPage(showEnvironmentDiagnostics: false),
      session: FixedSession(parentId, email: 'guardian@example.com'),
      students: ScriptedStudentReadGateway(),
      destinations: ScriptedDestinationGateway(),
    );
    expect(find.text('Orbit Point 1.0.0+1'), findsOneWidget);
    expect(find.textContaining(PointContract.stagingRef), findsNothing);
    expect(find.textContaining('Staging project'), findsNothing);
  });

  testWidgets('bus page does not invent coordinates or a moving bus', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway();
    final students = ScriptedStudentReadGateway(
      link: const GuardianLink(
        studentId: studentId,
        parentId: parentId,
        relationship: 'Guardian',
      ),
      sis: const SisIdentityRow(
        sisStudentId: 'SIS-1',
        fullName: 'Enrolled Name',
        enrollmentStatus: 'active',
        isArchived: false,
      ),
      ops: const StudentOpsRow(
        id: studentId,
        sisStudentId: 'SIS-1',
        currentStatus: 'off_bus',
        missingStatus: 'NONE',
        hasCurrentBus: false,
        isArchived: false,
      ),
    );
    await pumpScoped(
      tester,
      page: const PointBusRoutePage(),
      session: FixedSession(parentId),
      students: students,
      destinations: destinations,
      arguments: const PointStudentRouteArgs(studentId),
    );
    expect(find.byKey(const Key('map-unavailable')), findsOneWidget);
    expect(
      find.textContaining('Live location is not available'),
      findsOneWidget,
    );
    expect(find.textContaining('bus is moving'), findsNothing);
    expect(find.textContaining('30.0'), findsNothing);
    expect(destinations.transportCalls, 1);
  });

  testWidgets('profile page shows the session email', (tester) async {
    final destinations = ScriptedDestinationGateway(
      parent: const ParentRecord(
        id: parentId,
        fullName: 'Ada Guardian',
        nodeFlag: false,
        verifiedAt: null,
        createdAt: null,
      ),
    );
    await pumpScoped(
      tester,
      page: const PointProfilePage(),
      session: FixedSession(
        parentId,
        email: 'guardian@example.com',
        emailVerified: true,
      ),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
    );
    expect(find.text('guardian@example.com'), findsOneWidget);
    expect(find.text('Email verified'), findsOneWidget);
    expect(find.text('Ada Guardian'), findsOneWidget);
  });

  testWidgets('ride options with a bad route argument does not query', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway();
    await pumpScoped(
      tester,
      page: const PointRideOptionsPage(),
      session: FixedSession(parentId),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
      arguments: const PointStudentRouteArgs('Enrolled Name'),
    );
    expect(find.text(PointContract.invalidIdMessage), findsOneWidget);
    expect(destinations.queriedIds, isEmpty);
  });
}
