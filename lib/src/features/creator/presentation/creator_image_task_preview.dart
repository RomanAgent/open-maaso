import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/creator/application/creator_image_tasks.dart';

/// The result stays a server completion. This separate, explicit interaction
/// may attach a verified local image to its unchanged creator draft.
Future<bool> showCreatorImageTaskPreview(
  BuildContext context,
  AgentTaskJob job,
) async {
  final tasks = appServices.maybeFind<CreatorImageTasks>();
  if (tasks == null) return false;
  final preview = await tasks.preview(job.id, expectedAttempt: job.attempt);
  if (!context.mounted || !tasks.isPreviewCurrent(preview)) {
    preview.close();
    return false;
  }
  try {
    await showDialog<void>(
      context: context,
      builder: (context) => _ImagePreview(tasks: tasks, preview: preview),
    );
    return true;
  } finally {
    preview.close();
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.tasks, required this.preview});
  final CreatorImageTasks tasks;
  final CreatorImageTaskPreview preview;
  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  bool _presented = false;
  bool _applying = false;
  bool _failed = false;
  void _present() {
    if (_presented) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.tasks.isPreviewCurrent(widget.preview)) return;
      widget.preview.markPresented();
      setState(() => _presented = true);
    });
  }

  Future<void> _apply() async {
    if (!_presented || _applying) return;
    setState(() {
      _applying = true;
      _failed = false;
    });
    try {
      await widget.tasks.applyPreview(widget.preview);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final current = widget.tasks.isPreviewCurrent(widget.preview);
    return AlertDialog(
      title: Text('creator.task.preview'.tr),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (current)
                Image.file(
                  File(widget.preview.asset.localPath),
                  fit: BoxFit.contain,
                  frameBuilder: (context, child, frame, synchronous) {
                    if (frame != null || synchronous) _present();
                    return child;
                  },
                  errorBuilder: (_, _, _) =>
                      Text('creator.task.preview_failed'.tr),
                )
              else
                Text('home.task.action_unavailable'.tr),
              const SizedBox(height: 12),
              Text('creator.task.apply_hint'.tr),
              if (_failed) Text('creator.task.apply_failed'.tr),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('common.close'.tr),
        ),
        FilledButton(
          onPressed: current && _presented && !_applying ? _apply : null,
          child: Text('creator.task.apply'.tr),
        ),
      ],
    );
  });
}
