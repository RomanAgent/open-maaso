import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';

/// Native controls represent explicit user intent; no page message can grant
/// the Agent a seat. They share the existing non-sampling platform-view chrome.
class SurfaceBundleControls extends StatelessWidget {
  const SurfaceBundleControls({super.key, required this.presentation});
  final SurfaceBundlePresentation presentation;

  @override
  Widget build(BuildContext context) => presentation.isGame
      ? const SizedBox.shrink()
      : StreamBuilder<void>(
          stream: presentation.onControlsChanged,
          builder: (context, _) => _appletControls(context),
        );

  Widget _appletControls(BuildContext context) {
    final grant = presentation.appletGrant;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      children: [
        AppGlassIconButton(
          key: const ValueKey('project-control-grant'),
          size: 48,
          icon: Icons.smart_toy_outlined,
          tooltip: 'project_control.allow'.tr,
          onPressed: presentation.canGrantApplet
              ? () => _requestAppletGrant(context)
              : null,
        ),
        AppGlassIconButton(
          key: const ValueKey('project-control-take-over'),
          size: 48,
          icon: Icons.pan_tool_outlined,
          tooltip: 'project_control.take_over'.tr,
          onPressed: grant == null
              ? null
              : () => _run(context, presentation.takeOverAppletFromNative),
        ),
        Text(
          grant == null
              ? 'project_control.manual'.tr
              : 'project_control.remaining'.trParams({
                  'count': '${grant.remainingActions}',
                }),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  void _requestAppletGrant(BuildContext context) {
    unawaited(() async {
      final purpose = await showAppGlassSheet<String>(
        context: context,
        builder: (_) => const _AppletGrantSheet(),
      );
      if (!context.mounted || purpose == null || !presentation.canGrantApplet) {
        return;
      }
      _run(context, () => presentation.grantAppletFromNative(purpose));
    }());
  }

  void _run(BuildContext context, Future<void> Function() operation) {
    unawaited(
      operation().catchError((Object _) {
        if (!context.mounted) return;
        showAppGlassNotice(
          title:
              (presentation.isGame
                      ? 'project_play.failed'
                      : 'project_control.failed')
                  .tr,
          message:
              (presentation.isGame
                      ? 'project_play.failed'
                      : 'project_control.failed')
                  .tr,
          icon: Icons.error_outline_rounded,
        );
      }),
    );
  }
}

class _AppletGrantSheet extends StatefulWidget {
  const _AppletGrantSheet();
  @override
  State<_AppletGrantSheet> createState() => _AppletGrantSheetState();
}

class _AppletGrantSheetState extends State<_AppletGrantSheet> {
  final _purpose = TextEditingController();
  @override
  void dispose() {
    _purpose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      key: const ValueKey('project-control-confirmation'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'project_control.allow'.tr,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text('project_control.permission'.tr),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('project-control-purpose'),
          controller: _purpose,
          maxLength: 800,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(labelText: 'project_control.purpose'.tr),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            AppGlassButton(
              primary: false,
              label: 'common.cancel'.tr,
              onPressed: () => Navigator.of(context).pop(),
            ),
            AppGlassButton(
              key: const ValueKey('project-control-confirm'),
              label: 'project_control.allow'.tr,
              onPressed: () => Navigator.of(context).pop(_purpose.text.trim()),
            ),
          ],
        ),
      ],
    ),
  );
}
