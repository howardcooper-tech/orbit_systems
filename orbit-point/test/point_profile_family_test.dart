import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_point/app.dart';
import 'package:orbit_point/data/destination_gateway.dart';
import 'package:orbit_point/data/destination_models.dart';
import 'package:orbit_point/data/gateway_exception.dart';
import 'package:orbit_point/data/point_models.dart';
import 'package:orbit_point/integration/point_contract.dart';
import 'package:orbit_point/state/family_roster.dart';
import 'package:orbit_point/state/profile_controller.dart';
import 'package:orbit_point/theme/orbit_theme.dart';
import 'package:orbit_point/widgets/family_member_card.dart';

import 'support/scripted_destination_gateway.dart';
import 'support/scripted_gateways.dart';

void main() {
  const studentId = '11111111-1111-4111-8111-111111111111';
  const otherStudentId = '44444444-4444-4444-8444-444444444444';
  const parentId = '22222222-2222-4222-8222-222222222222';
  const otherParentId = '55555555-5555-4555-8555-555555555555';
  const adultId = '66666666-6666-4666-8666-666666666666';
  const secondaryId = '77777777-7777-4777-8777-777777777777';
  const inviteId = '88888888-8888-4888-8888-888888888888';

  ParentRecord parent() {
    return const ParentRecord(
      id: parentId,
      fullName: 'Ada Guardian',
      nodeFlag: false,
      verifiedAt: null,
      createdAt: null,
    );
  }

  ScriptedStudentReadGateway students() {
    return ScriptedStudentReadGateway(
      link: const GuardianLink(
        studentId: studentId,
        parentId: parentId,
        relationship: 'Guardian',
      ),
      links: const [
        GuardianLink(
          studentId: studentId,
          parentId: parentId,
          relationship: 'Guardian',
        ),
        GuardianLink(
          studentId: otherStudentId,
          parentId: otherParentId,
          relationship: 'Guardian',
        ),
      ],
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
        fullName: 'Returned Student',
        enrollmentStatus: 'active',
        isArchived: false,
      ),
    );
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    required FixedSession session,
    required ScriptedStudentReadGateway students,
    required ScriptedDestinationGateway destinations,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      OrbitPointApp.live(
        session: session,
        students: students,
        destinations: destinations,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  test('invitation columns do not include a token', () {
    expect(DestinationContract.invitationColumns.contains('token'), isFalse);
    expect(
      DestinationContract.invitationColumns.contains('token_hash'),
      isFalse,
    );
  });

  test('roster uses gateway rows and omits grade when none is supplied', () {
    final members = buildFamilyRoster(
      students: const [
        NamedStudentLink(
          studentId: studentId,
          displayName: 'Returned Student',
          relationship: 'Guardian',
        ),
      ],
      adults: const [
        SecondaryAuthorization(
          id: adultId,
          studentId: studentId,
          secondaryId: secondaryId,
          relationshipLabel: 'Aunt',
          morningTrack: true,
          afternoonTrack: false,
          chaperoneApproved: false,
        ),
      ],
      profiles: const {},
      invitations: [
        FamilyInvitation(
          id: inviteId,
          studentId: studentId,
          invitedByParentId: parentId,
          relationshipLabel: 'Aunt',
          status: 'PENDING',
          expiresAt: DateTime.now().add(const Duration(days: 2)),
        ),
      ],
      now: DateTime.now(),
    );
    expect(members.map((item) => item.id), [studentId, adultId, inviteId]);
    expect(members.first.relationshipLine, 'Student');
    expect(members.first.relationshipLine.contains('Grade'), isFalse);
    expect(members[1].status, FamilyLinkStatus.linked);
    expect(members[1].displayName, 'Name unavailable');
    expect(members[2].status, FamilyLinkStatus.invitationPending);
    expect(studentRelationshipLine('4'), 'Student • Grade 4');
  });

  testWidgets('status labels follow the model', (tester) async {
    const cases = <FamilyLinkStatus, String>{
      FamilyLinkStatus.linked: 'LINKED',
      FamilyLinkStatus.accountFound: 'ACCOUNT FOUND',
      FamilyLinkStatus.invitationPending: 'INVITATION PENDING',
      FamilyLinkStatus.invitationAvailable: 'INVITATION AVAILABLE',
      FamilyLinkStatus.verificationRequired: 'VERIFICATION REQUIRED',
      FamilyLinkStatus.notAuthorized: 'NOT AUTHORIZED',
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOrbitTheme(),
        home: Scaffold(
          body: ListView(
            children: [
              for (final entry in cases.entries)
                FamilyMemberCard(
                  member: FamilyMember(
                    id: '99999999-9999-4999-8999-99999999999${entry.key.index}',
                    kind: entry.key == FamilyLinkStatus.accountFound
                        ? FamilyMemberKind.guardian
                        : FamilyMemberKind.authorizedAdult,
                    status: entry.key,
                    displayName: 'Returned Adult',
                    relationshipLine: entry.key == FamilyLinkStatus.accountFound
                        ? 'Parent / Guardian'
                        : 'Authorized Adult',
                    studentId: null,
                    relationshipDetail: null,
                    morningTrack: null,
                    afternoonTrack: null,
                    grade: null,
                    schoolName: null,
                    expiresAt: null,
                    openStudent: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    for (final entry in cases.entries) {
      expect(find.text(entry.value), findsOneWidget);
    }
    expect(find.text('Parent / Guardian'), findsOneWidget);
    expect(find.text('LINKED'), findsOneWidget);
    expect(find.text('Maya Morgan'), findsNothing);
  });

  testWidgets('profile opens from Point Home and shows the guardian', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway(parent: parent());
    await pumpApp(
      tester,
      session: FixedSession(
        parentId,
        email: 'guardian@example.com',
        emailVerified: true,
      ),
      students: students(),
      destinations: destinations,
      size: const Size(800, 1600),
    );
    await tester.pumpAndSettle();
    expect(find.text('MY FAMILY'), findsNothing);
    await tester.ensureVisible(find.text('PROFILE'));
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    expect(find.text('PROFILE'), findsWidgets);
    expect(find.text('MY FAMILY'), findsOneWidget);
    expect(find.text('Ada Guardian'), findsOneWidget);
    expect(find.text('guardian@example.com'), findsOneWidget);
    expect(find.text('Email verified'), findsOneWidget);
    expect(find.text('Maya Morgan'), findsNothing);
    expect(find.text('Jordan Morgan'), findsNothing);
  });

  testWidgets('linked students come from the gateway and use their ids', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway(
      parent: parent(),
      secondaries: const [
        SecondaryAuthorization(
          id: adultId,
          studentId: studentId,
          secondaryId: secondaryId,
          relationshipLabel: 'Aunt',
          morningTrack: false,
          afternoonTrack: true,
          chaperoneApproved: false,
        ),
      ],
      secondaryProfiles: const {
        secondaryId: SecondaryProfile(
          id: secondaryId,
          displayName: 'Returned Adult',
        ),
      },
      invitations: [
        FamilyInvitation(
          id: inviteId,
          studentId: studentId,
          invitedByParentId: parentId,
          relationshipLabel: 'Aunt',
          status: 'PENDING',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
        ),
      ],
    );
    await pumpApp(
      tester,
      session: FixedSession(parentId, email: 'guardian@example.com'),
      students: students(),
      destinations: destinations,
      size: const Size(800, 1800),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    expect(find.text('Returned Student'), findsOneWidget);
    expect(find.text('Returned Adult'), findsOneWidget);
    expect(find.text('Name not returned'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('family-member-$studentId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('family-member-$adultId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('family-member-$inviteId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('family-member-$otherStudentId')),
      findsNothing,
    );
    expect(find.text('Maya Morgan'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('family-status-$studentId')))
          .data,
      'LINKED',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('family-status-$inviteId')))
          .data,
      'INVITATION PENDING',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('family-relationship-$studentId')),
          )
          .data,
      'Student',
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('family-member-$studentId')),
    );
    await tester.tap(find.byKey(const ValueKey('family-member-$studentId')));
    await tester.pumpAndSettle();
    expect(find.text(PointContract.gradeUnavailable), findsOneWidget);
    expect(find.text(PointContract.schoolUnavailable), findsOneWidget);
    expect(find.textContaining('Medical'), findsNothing);
    expect(find.textContaining('PIN'), findsNothing);
    expect(find.textContaining('GPS'), findsNothing);
    expect(find.textContaining('fob'), findsNothing);
    await tester.tap(find.byKey(const Key('family-open-student')));
    await tester.pumpAndSettle();
    expect(destinations.queriedIds, contains(studentId));
    expect(find.text('Returned Student'), findsWidgets);
    expect(find.text(otherStudentId), findsNothing);
  });

  testWidgets('invite does not grant access or report success', (tester) async {
    final destinations = ScriptedDestinationGateway(parent: parent());
    await pumpApp(
      tester,
      session: FixedSession(parentId, email: 'guardian@example.com'),
      students: students(),
      destinations: destinations,
      size: const Size(800, 1800),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('profile-invite')));
    await tester.tap(find.byKey(const Key('profile-invite')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-invite-email')), findsNothing);
    expect(find.byKey(const Key('profile-invite-submit')), findsNothing);
    expect(find.byKey(const Key('profile-invite-result')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('profile-invite-result'))).data,
      DestinationContract.familyInviteUnavailable,
    );
    expect(destinations.authorizationWrites, 0);
    expect(destinations.inviteCalls, 0);
    expect(find.textContaining('Invite sent'), findsNothing);
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Maya Morgan'), findsNothing);
  });

  testWidgets('settings gear and home navigation', (tester) async {
    final destinations = ScriptedDestinationGateway(parent: parent());
    await pumpApp(
      tester,
      session: FixedSession(parentId, email: 'guardian@example.com'),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
      size: const Size(800, 1600),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('PROFILE'));
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('profile-home')));
    await tester.tap(find.byKey(const Key('profile-home')));
    await tester.pumpAndSettle();
    expect(find.text('Orbit Point'), findsOneWidget);
    expect(find.text('MY FAMILY'), findsNothing);
  });

  testWidgets('edit profile rejects an empty name and a failed save', (
    tester,
  ) async {
    final destinations = ScriptedDestinationGateway(parent: parent());
    await pumpApp(
      tester,
      session: FixedSession(
        parentId,
        email: 'guardian@example.com',
        emailVerified: true,
      ),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
      size: const Size(800, 1800),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-edit')));
    await tester.pumpAndSettle();
    expect(find.text(DestinationContract.emailReadOnly), findsOneWidget);
    expect(
      find.text(DestinationContract.photoUploadUnavailable),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const Key('profile-name')), ' ');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    expect(destinations.nameUpdates, 0);
    expect(find.text('Saved'), findsNothing);
    expect(
      find.text('Enter a name of 200 characters or less.'),
      findsOneWidget,
    );

    destinations.nameUpdateFailure = const NetworkFailure();
    await tester.enterText(
      find.byKey(const Key('profile-name')),
      'Ada Updated',
    );
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    expect(destinations.nameUpdates, 1);
    expect(destinations.parent?.fullName, 'Ada Guardian');
    expect(find.text('Saved'), findsNothing);
    expect(find.text('The name could not be saved.'), findsOneWidget);
  });

  testWidgets('empty, loading, and error retry', (tester) async {
    final gate = Completer<void>();
    final destinations = ScriptedDestinationGateway(parent: parent())
      ..pause = gate;
    await pumpApp(
      tester,
      session: FixedSession(parentId, email: 'guardian@example.com'),
      students: ScriptedStudentReadGateway(),
      destinations: destinations,
      size: const Size(800, 1600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROFILE'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading profile'), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('No family members were returned.'), findsOneWidget);
    expect(find.text('Maya Morgan'), findsNothing);

    destinations.failure = const NetworkFailure();
    destinations.pause = null;
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROFILE'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load profile'), findsOneWidget);
    destinations.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Ada Guardian'), findsOneWidget);
  });

  testWidgets('language save follows the stored preference row', (
    tester,
  ) async {
    final missing = ScriptedDestinationGateway(parent: parent());
    final controller = ProfileController(
      destinations: missing,
      students: ScriptedStudentReadGateway(),
      session: FixedSession(parentId, email: 'guardian@example.com'),
    );
    await controller.load();
    final saved = await controller.saveLanguage('es');
    expect(saved, isFalse);
    expect(controller.state.message, DestinationContract.languageNotStored);
    expect(missing.languageWrites, 0);
    expect(controller.state.languageCode, isNull);
    controller.dispose();

    final stored = ScriptedDestinationGateway(
      parent: parent(),
      languageStored: true,
      languageCode: 'en',
    );
    final ready = ProfileController(
      destinations: stored,
      students: ScriptedStudentReadGateway(),
      session: FixedSession(parentId),
    );
    await ready.load();
    final wrote = await ready.saveLanguage('es');
    expect(wrote, isTrue);
    expect(stored.languageWrites, 1);
    expect(stored.languageCode, 'es');
    expect(ready.state.message, DestinationContract.languageSavedNote);
    expect(ready.state.message, isNot(contains('whole app')));
    ready.dispose();
  });

  testWidgets('profile column stays narrow on a phone and a desktop', (
    tester,
  ) async {
    Future<void> openAt(Size size) async {
      final destinations = ScriptedDestinationGateway(parent: parent());
      await pumpApp(
        tester,
        session: FixedSession(parentId, email: 'guardian@example.com'),
        students: students(),
        destinations: destinations,
        size: size,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('PROFILE'));
      await tester.tap(find.text('PROFILE'));
      await tester.pumpAndSettle();
    }

    await openAt(const Size(390, 844));
    final phone = tester.getSize(find.byKey(const Key('profile-column')));
    expect(phone.width, lessThanOrEqualTo(390));
    expect(phone.width, greaterThan(300));
    expect(find.text('MY FAMILY'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Home'), 200);
    expect(find.text('Home'), findsOneWidget);

    await openAt(const Size(1440, 900));
    final desktop = tester.getSize(find.byKey(const Key('profile-column')));
    final origin = tester.getTopLeft(find.byKey(const Key('profile-column')));
    expect(desktop.width, OrbitLayout.profileColumn);
    expect(origin.dx, greaterThan(200));
    expect(origin.dx + desktop.width, lessThan(1440));
  });
}
