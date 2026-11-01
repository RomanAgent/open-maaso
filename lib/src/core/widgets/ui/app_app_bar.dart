import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Style-aware top bar.  A floating [AppSurface] pill that adapts to the
/// active style, sized to sit under the status bar.  Implements
/// [PreferredSizeWidget] so it drops straight into `Scaffold.appBar`.
class AppAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
    this.centerTitle = true,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final bool centerTitle;

  static const double _barHeight = 52;

  @override
  Size get preferredSize => const Size.fromHeight(_barHeight + 12);

  @override
  Widget build(BuildContext context) {
    return AppGlassAppBar(
      title: title,
      leading: leading,
      actions: actions,
      centerTitle: centerTitle,
      height: _barHeight,
    );
  }
}
