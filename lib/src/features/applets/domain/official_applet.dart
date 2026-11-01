import 'package:flutter/material.dart';

import 'package:maaso/src/features/applets/presentation/ble_projector/ble_projector_applet.dart';

/// A first-party ("官方") applet: a native Flutter mini-app curated by Maaso,
/// distinct from the agent-authored HTML applets in the Hub. Official applets
/// may touch native capabilities (Bluetooth, camera, …) that the sandboxed
/// agent applets can't, so they ship as real screens.
///
/// They surface in the Official section of the Widgets Hub and are reachable by
/// slash command (see AppRoutes).
class OfficialApplet {
  const OfficialApplet({
    required this.id,
    required this.nameKey,
    required this.icon,
    required this.color,
    required this.builder,
    this.requiresSkillId,
  });

  final String id;

  /// i18n key for the display name.
  final String nameKey;
  final IconData icon;
  final Color color;

  /// The applet screen.
  final Widget Function() builder;

  /// When set, the applet is shown greyed/disabled unless this skill id is
  /// enabled for the active agent (e.g. the projector applet needs its skill).
  final String? requiresSkillId;
}

/// All official applets. Add one entry to publish a new first-party mini-app.
class OfficialAppletRegistry {
  static const _systemBlue = Color(0xFF007AFF);

  static final List<OfficialApplet> all = [
    OfficialApplet(
      id: 'ble_yoturetoys_projector',
      nameKey: 'applet.projector.name',
      icon: Icons.cast_rounded,
      color: _systemBlue,
      requiresSkillId: 'ble_yoturetoys_projector',
      builder: () => const BleProjectorApplet(),
    ),
  ];

  static OfficialApplet? byId(String id) {
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }
}
