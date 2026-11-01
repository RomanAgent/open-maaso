import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Pure display of a host-selected edit target. It neither issues editing
/// authority nor owns the composer's text, images or send lifecycle.
class HomeProjectBuildEditBanner extends StatelessWidget {
  const HomeProjectBuildEditBanner({
    super.key,
    required this.title,
    required this.onClear,
    this.enabled = true,
  });
  final String title;
  final VoidCallback onClear;
  final bool enabled;

  static TextStyle _style(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium ??
      const TextStyle(fontSize: 15, height: 1.6);

  /// The composer reserves the same two-line, scaled text box it renders.
  static double heightFor(BuildContext context) {
    final style = _style(context);
    final line =
        (MediaQuery.textScalerOf(context).scale(style.fontSize ?? 15) *
                (style.height ?? 1.6))
            .ceilToDouble();
    return math.max(48, line * 2 + 8);
  }

  @override
  Widget build(BuildContext context) => AppGlassSurface(
    key: const ValueKey('project-build-edit-banner'),
    role: AppGlassSurfaceRole.control,
    height: heightFor(context),
    child: Row(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.edit_note_rounded, size: 24),
        ),
        Expanded(
          child: Text(
            'project_build.saved.edit_target'.trParams({'name': title}),
            key: const ValueKey('project-build-edit-reference'),
            style: _style(context),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          key: const ValueKey('project-build-edit-clear'),
          tooltip: 'project_build.saved.edit_clear'.tr,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          onPressed: enabled ? onClear : null,
          icon: const Icon(Icons.close_rounded, size: 24),
        ),
      ],
    ),
  );
}
