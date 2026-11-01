import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_transient.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

typedef AppletSaveConfirmation = Future<bool> Function(SurfaceProject project);

/// A host-owned confirmation after preview, before any local or cloud write.
Future<bool> confirmGeneratedAppletSave(
  SurfaceProject project, {
  required AppLocale locale,
  required bool Function() isCurrent,
}) async {
  final context = appNavigation.context;
  if (context == null || !context.mounted || !isCurrent()) return false;
  final chinese = locale == AppLocale.zh;
  BuildContext? dialogContext;
  final watcher = Timer.periodic(const Duration(milliseconds: 200), (_) {
    final active = dialogContext;
    if (active != null && active.mounted && !isCurrent()) {
      dialogContext = null;
      Navigator.of(active).pop(false);
    }
  });
  try {
    return await showAppGlassDialog<bool>(
          context: context,
          builder: (currentContext) {
            dialogContext = currentContext;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chinese ? '保存到我的小程序？' : 'Save to My mini apps?',
                  style: Theme.of(currentContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(project.title),
                const SizedBox(height: 8),
                Text(
                  chinese
                      ? '确认后保存。你可以在“我的”中继续编辑、发布或删除。'
                      : 'Save this preview to edit, publish, or delete it from My mini apps.',
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      key: const ValueKey('applet-save-cancel'),
                      onPressed: () => Navigator.of(currentContext).pop(false),
                      child: Text(chinese ? '暂不保存' : 'Do not save'),
                    ),
                    FilledButton(
                      key: const ValueKey('applet-save-confirm'),
                      onPressed: () => Navigator.of(currentContext).pop(true),
                      child: Text(chinese ? '确认保存' : 'Save'),
                    ),
                  ],
                ),
              ],
            );
          },
        ) ==
        true;
  } finally {
    watcher.cancel();
  }
}
