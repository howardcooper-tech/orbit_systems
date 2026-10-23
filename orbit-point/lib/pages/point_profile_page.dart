import 'package:flutter/material.dart';
import 'package:orbit_point/data/destination_gateway.dart';
import 'package:orbit_point/data/destination_models.dart';
import 'package:orbit_point/navigation/point_routes.dart';
import 'package:orbit_point/orbit_scope.dart';
import 'package:orbit_point/state/family_roster.dart';
import 'package:orbit_point/state/profile_controller.dart';
import 'package:orbit_point/state/profile_language.dart';
import 'package:orbit_point/theme/orbit_theme.dart';
import 'package:orbit_point/widgets/family_member_card.dart';
import 'package:orbit_point/widgets/orbit_card.dart';
import 'package:orbit_point/widgets/point_page_frame.dart';

class PointProfilePage extends StatefulWidget {
  const PointProfilePage({super.key});

  @override
  State<PointProfilePage> createState() => _PointProfilePageState();
}

class _PointProfilePageState extends State<PointProfilePage> {
  ProfileController? _controller;
  var _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final scope = OrbitScope.of(context);
    final controller = ProfileController(
      destinations: scope.destinations,
      students: scope.students,
      session: scope.session,
    );
    controller.addListener(_onChange);
    _controller = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller.load();
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChange);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _openEdit() async {
    await Navigator.of(context).pushNamed(PointRoutes.editProfile);
    if (!mounted) return;
    await _controller?.load();
  }

  void _openMember(FamilyMember member) {
    if (!canOpenFamilyMember(member.id)) return;
    Navigator.of(context).pushNamed(
      PointRoutes.familyMember,
      arguments: PointFamilyMemberRouteArgs(member.id),
    );
  }

  Future<void> _invite() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Invite'),
          content: const Text(
            DestinationContract.familyInviteUnavailable,
            key: Key('profile-invite-result'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _onLanguage(String? code) async {
    final controller = _controller;
    if (controller == null || code == null) return;
    final current = controller.state.languageCode ?? 'en';
    if (code == current && controller.state.languageStored) return;
    await controller.saveLanguage(code);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final state = controller?.state;
    return Scaffold(
      backgroundColor: OrbitColors.navy,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: OrbitLayout.profileColumn,
            ),
            child: KeyedSubtree(
              key: const Key('profile-column'),
              child: Column(
                children: [
                  _ProfileHeader(
                    onSettings: () {
                      Navigator.of(context).pushNamed(PointRoutes.settings);
                    },
                  ),
                  Expanded(
                    child: state == null || state.phase == PointLoad.loading
                        ? const PointStateCard(
                            title: 'Profile',
                            message: 'Loading profile',
                            loading: true,
                          )
                        : state.phase == PointLoad.ready
                        ? _ProfileBody(
                            state: state,
                            onLanguage: _onLanguage,
                            onEdit: _openEdit,
                            onMember: _openMember,
                            onInvite: _invite,
                            onHome: () => popToPointHome(context),
                          )
                        : PointStateCard(
                            title: state.phase == PointLoad.denied
                                ? 'Permission denied'
                                : 'Could not load profile',
                            message:
                                state.message ??
                                'The profile could not be loaded.',
                            onRetry: controller!.load,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
      child: Row(
        children: [
          BackButton(onPressed: () => popToPointHome(context)),
          const Expanded(
            child: Text(
              'PROFILE',
              style: TextStyle(
                color: OrbitColors.text,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          IconButton(
            key: const Key('profile-settings'),
            tooltip: 'Settings',
            onPressed: onSettings,
            icon: const Icon(Icons.settings, color: OrbitColors.text),
          ),
        ],
      ),
    );
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody({
    required this.state,
    required this.onLanguage,
    required this.onEdit,
    required this.onMember,
    required this.onInvite,
    required this.onHome,
  });

  final ProfileState state;
  final ValueChanged<String?> onLanguage;
  final VoidCallback onEdit;
  final ValueChanged<FamilyMember> onMember;
  final VoidCallback onInvite;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final record = state.record;
    final language = state.languageCode ?? 'en';
    final choices = profileLanguageChoices(state.languageCode);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OrbitSpace.page,
        8,
        OrbitSpace.page,
        28,
      ),
      children: [
        DropdownButtonFormField<String>(
          key: const Key('profile-language'),
          // Controlled so a failed save returns to the last confirmed code.
          // ignore: deprecated_member_use
          value: choices.contains(language) ? language : 'en',
          items: [
            for (final code in choices)
              DropdownMenuItem(
                value: code,
                child: Text(profileLanguageLabel(code)),
              ),
          ],
          onChanged: state.saving ? null : onLanguage,
          decoration: InputDecoration(
            labelText: 'Language',
            filled: true,
            fillColor: OrbitColors.navyCard,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(OrbitRadius.tile),
              borderSide: const BorderSide(color: OrbitColors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(OrbitRadius.tile),
              borderSide: const BorderSide(color: OrbitColors.gold),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          DestinationContract.languageDisplayNote,
          style: TextStyle(color: OrbitColors.muted, fontSize: 12),
        ),
        if (state.message != null) ...[
          const SizedBox(height: 8),
          Text(
            state.message!,
            style: TextStyle(
              color: state.message == DestinationContract.languageSavedNote
                  ? OrbitColors.muted
                  : OrbitColors.danger,
            ),
          ),
        ],
        const SizedBox(height: 16),
        _AccountCard(state: state, record: record, onEdit: onEdit),
        const SizedBox(height: 16),
        _FamilyCard(
          members: state.members,
          onMember: onMember,
          onInvite: onInvite,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('profile-home'),
            style: ElevatedButton.styleFrom(
              backgroundColor: OrbitColors.navyRaised,
              foregroundColor: OrbitColors.text,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(OrbitRadius.tile),
              ),
            ),
            onPressed: onHome,
            child: const Text(
              'Home',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.state,
    required this.record,
    required this.onEdit,
  });

  final ProfileState state;
  final ParentRecord? record;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final name = record?.fullName ?? OrbitCopy.notAvailable;
    final email = state.email ?? OrbitCopy.notAvailable;
    return OrbitCard(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PointInitialsAvatar(
                label: name,
                photoUrl: record?.photoUrl,
                radius: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      email,
                      style: const TextStyle(color: OrbitColors.muted),
                    ),
                    Text(
                      state.email == null
                          ? OrbitCopy.notAvailable
                          : state.emailVerified
                          ? 'Email verified'
                          : 'Email not verified',
                      key: const Key('profile-email'),
                      style: const TextStyle(color: OrbitColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PhoneLine(state: state),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const Key('profile-edit'),
              onPressed: record == null ? null : onEdit,
              child: const Text('Edit Profile'),
            ),
          ),
          if (record == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'The parent record was not returned, so the name cannot be edited.',
                style: TextStyle(color: OrbitColors.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhoneLine extends StatelessWidget {
  const _PhoneLine({required this.state});

  final ProfileState state;

  @override
  Widget build(BuildContext context) {
    if (state.contactStored) {
      return PointInfoRow(
        label: 'Telephone',
        value: state.contactPhone ?? OrbitCopy.notAvailable,
      );
    }
    if (state.phone != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PointInfoRow(label: 'Telephone', value: state.phone!),
          const Text(
            'Sign-in telephone. This screen does not change it.',
            style: TextStyle(color: OrbitColors.muted, fontSize: 12),
          ),
        ],
      );
    }
    return const PointInfoRow(
      label: 'Telephone',
      value: DestinationContract.telephoneUnavailable,
    );
  }
}

class _FamilyCard extends StatelessWidget {
  const _FamilyCard({
    required this.members,
    required this.onMember,
    required this.onInvite,
  });

  final List<FamilyMember> members;
  final ValueChanged<FamilyMember> onMember;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrbitColors.navyCard,
        borderRadius: BorderRadius.circular(OrbitRadius.card),
        border: Border.all(color: OrbitColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          children: [
            const Text(
              'MY FAMILY',
              style: TextStyle(
                color: OrbitColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Family members recorded by your school.',
              textAlign: TextAlign.center,
              style: TextStyle(color: OrbitColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (members.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No family members were returned.',
                  style: TextStyle(color: OrbitColors.muted),
                ),
              )
            else
              for (final member in members) ...[
                FamilyMemberCard(
                  member: member,
                  onTap: canOpenFamilyMember(member.id)
                      ? () => onMember(member)
                      : null,
                ),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 6),
            ElevatedButton(
              key: const Key('profile-invite'),
              style: ElevatedButton.styleFrom(
                backgroundColor: OrbitColors.navy,
                foregroundColor: OrbitColors.text,
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(OrbitRadius.tile),
                ),
              ),
              onPressed: onInvite,
              child: const Text('Invite'),
            ),
            const SizedBox(height: 14),
            const Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 6,
              children: [
                _LegendItem(icon: Icons.check, label: 'Account Found'),
                _LegendItem(icon: Icons.done_all, label: 'Linked'),
                Text(
                  'Invite = No Orbit Account',
                  style: TextStyle(color: OrbitColors.muted, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: OrbitColors.statusBoarded),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: OrbitColors.muted, fontSize: 11),
        ),
      ],
    );
  }
}
