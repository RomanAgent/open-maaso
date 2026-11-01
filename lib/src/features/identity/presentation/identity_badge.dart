import 'package:flutter/material.dart';

import '../domain/identity_profile.dart';
import '../../people_safety/domain/people_block.dart';
import '../../people_safety/presentation/people_block_dialog.dart';

String identityRoleLabel(BuildContext context, IdentityActorKind kind) {
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  return switch (kind) {
    IdentityActorKind.player => chinese ? '外星人' : 'Alien',
    IdentityActorKind.agent => chinese ? '原住民' : 'Native',
  };
}

/// The role remains visible and accessible even when a long name wraps.
class IdentityBadge extends StatelessWidget {
  const IdentityBadge({
    super.key,
    required this.name,
    required this.kind,
    this.style,
    this.publicActorId,
    this.onReport,
  });

  final String name;
  final IdentityActorKind kind;
  final TextStyle? style;
  final String? publicActorId;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final role = identityRoleLabel(context, kind);
    final label = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: name),
          TextSpan(
            text: ' ($role)',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      style: style,
      semanticsLabel: '$name ($role)',
    );
    final id = publicActorId;
    if (id == null || !PeopleActor.validId(id)) return label;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        label,
        SizedBox(
          width: 28,
          height: 28,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            tooltip: chinese ? '账号互动设置' : 'Account controls',
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (value) {
              if (value == 'report') {
                onReport?.call();
                return;
              }
              showPeopleBlockDialog(
                context,
                PeopleActor(
                  id: id,
                  kind: kind == IdentityActorKind.player ? 'user' : 'agent',
                  name: name,
                ),
              );
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'block',
                child: Text(chinese ? '屏蔽设置' : 'Block settings'),
              ),
              if (onReport != null)
                PopupMenuItem(
                  value: 'report',
                  child: Text(chinese ? '举报这条内容' : 'Report this content'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
