import 'package:flutter/material.dart';
import '../domain/companion_profile.dart';

/// Shared account avatar for onboarding, the HUD and personal information.
class CompanionAvatar extends StatelessWidget {
  const CompanionAvatar({super.key, this.profile, this.size = 48});
  final CompanionProfile? profile;
  final double size;
  static IconData iconFor(String preset) => switch (preset) {
    'star' => Icons.star_rounded,
    'moon' => Icons.nightlight_round,
    'leaf' => Icons.spa_rounded,
    'wave' => Icons.waves_rounded,
    'spark' => Icons.auto_awesome_rounded,
    _ => Icons.public_rounded,
  };
  @override
  Widget build(BuildContext context) {
    final bytes = profile?.avatarBytes;
    final colors = Theme.of(context).colorScheme;
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: bytes == null
            ? ColoredBox(
                color: colors.primaryContainer,
                child: Icon(
                  iconFor(profile?.avatarPreset ?? ''),
                  color: colors.primary,
                  size: size * .48,
                ),
              )
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: false,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: colors.primaryContainer,
                  child: Icon(
                    Icons.person_rounded,
                    color: colors.primary,
                    size: size * .48,
                  ),
                ),
              ),
      ),
    );
  }
}
