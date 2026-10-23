import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbit_point/data/destination_gateway.dart';
import 'package:orbit_point/integration/point_contract.dart';
import 'package:orbit_point/orbit_scope.dart';
import 'package:orbit_point/theme/orbit_theme.dart';
import 'package:orbit_point/widgets/orbit_card.dart';
import 'package:orbit_point/widgets/point_page_frame.dart';

class PointSettingsPage extends StatelessWidget {
  const PointSettingsPage({
    super.key,
    this.showEnvironmentDiagnostics = kDebugMode,
  });

  final bool showEnvironmentDiagnostics;

  Future<void> _confirmSignOut(BuildContext context) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sign out'),
          content: const Text('Sign out of Orbit Point on this device?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('confirm-sign-out'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (approved != true || !context.mounted) return;
    await OrbitScope.of(context).auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final session = OrbitScope.of(context).session;
    final email = session.email ?? OrbitCopy.notAvailable;
    return PointDestinationScaffold(
      title: 'Settings',
      body: PointScroll(
        children: [
          OrbitCard(
            title: 'Account',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(email),
                const SizedBox(height: 4),
                Text(
                  session.emailVerified
                      ? 'Email verified'
                      : 'Email not verified',
                  style: const TextStyle(color: OrbitColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const OrbitCard(
            title: 'Notifications',
            child: Text(DestinationContract.notificationPrefsUnavailable),
          ),
          const SizedBox(height: 12),
          OrbitCard(
            title: 'Security',
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('settings-sign-out'),
                onPressed: () => _confirmSignOut(context),
                child: const Text('Sign out'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          OrbitCard(
            title: 'App',
            child: Text(
              PointContract.settingsAbout(
                includeEnvironment: showEnvironmentDiagnostics,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const OrbitCard(
            title: 'Privacy',
            child: Text(
              'Point shows guardian-scoped records returned by the server. '
              'Medical details, PINs, dates of birth, GPS tracks, and fob data are not requested. '
              'This screen does not save a preference.',
            ),
          ),
        ],
      ),
    );
  }
}
