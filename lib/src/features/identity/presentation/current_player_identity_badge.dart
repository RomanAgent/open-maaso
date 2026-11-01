import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import '../application/identity_service.dart';
import '../domain/identity_profile.dart';
import 'identity_badge.dart';

/// The server-confirmed author of the nearby human comment input. Public-write
/// authorization remains in the account-bound gateway, independent of this label.
class CurrentPlayerIdentityBadge extends StatelessWidget {
  const CurrentPlayerIdentityBadge({super.key, this.style});

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(() {
      final profile = appServices.maybeFind<IdentityService>()?.profile;
      if (profile == null || !profile.completed) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: IdentityBadge(
          name: profile.playerName,
          kind: IdentityActorKind.player,
          style: style,
        ),
      );
    });
  }
}
