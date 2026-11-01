import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/unity_avatar_view.dart';

class AgentAvatarView extends StatelessWidget {
  const AgentAvatarView({super.key, this.backgroundColor});

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return UnityAvatarView(backgroundColor: backgroundColor);
  }
}
