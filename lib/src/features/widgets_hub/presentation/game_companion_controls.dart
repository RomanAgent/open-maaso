import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/application/game_perception_coordinator.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'game_frost_chrome.dart';

/// Opens companion settings from the player's top row.
class GameCompanionControlsButton extends StatelessWidget {
  const GameCompanionControlsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final service = appServices.maybeFind<GameVoiceCompanionService>();
    if (service == null) return const SizedBox.shrink();
    return _GameCompanionRevisionBuilder(
      revision: service.revision,
      builder: (context) => GameFrostIconButton(
        key: const ValueKey('game-companion-controls'),
        icon: service.preferences.enabled
            ? Icons.headset_mic_outlined
            : Icons.headset_off_outlined,
        tooltip: 'game_companion.controls'.tr,
        onPressed: service.currentSession == null
            ? null
            : () => _open(context, service),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    GameVoiceCompanionService service,
  ) async {
    final session = service.currentSession;
    if (session == null) return;
    final captureSupported = session.canCapture;
    final status = session.perceptionStatus;
    final scope = session.scopeKey;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => GameCompanionControlsSheet(
        service: service,
        scopeKey: scope,
        captureSupported: captureSupported,
        initialStatus: status,
      ),
    );
  }
}

class GameCompanionControlsSheet extends StatelessWidget {
  const GameCompanionControlsSheet({
    required this.service,
    required this.scopeKey,
    required this.captureSupported,
    this.initialStatus,
    super.key,
  });
  final GameVoiceCompanionService service;
  final String scopeKey;
  final bool captureSupported;
  final GamePerceptionStatus? initialStatus;

  bool get _current =>
      identical(appServices.maybeFind<GameVoiceCompanionService>(), service) &&
      AppletLocalOwnership.currentScopeKey() == scopeKey;

  void _mutate(void Function() action) {
    if (_current) action();
  }

  @override
  Widget build(BuildContext context) => _GameCompanionRevisionBuilder(
    revision: service.revision,
    builder: (context) {
      final prefs = service.preferences;
      final mic =
          service.microphoneRequested ??
          voiceInputRetirementCoordinator.voiceSessionRequestedFor(scopeKey);
      final status = service.currentSession?.perceptionStatus ?? initialStatus;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'game_companion.controls'.tr,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'game_companion.description'.tr,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('game_companion.enabled'.tr),
                  value: prefs.enabled,
                  onChanged: _current
                      ? (value) => _mutate(
                          () => service.setPreferences(
                            service.preferences.copyWith(enabled: value),
                          ),
                        )
                      : null,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('game_companion.microphone'.tr),
                  subtitle: Text('game_companion.microphone_hint'.tr),
                  value: mic,
                  onChanged: _current && prefs.enabled
                      ? (value) =>
                            _mutate(() => service.setMicrophoneEnabled(value))
                      : null,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('game_companion.sound'.tr),
                  value: service.spokenRepliesEnabled,
                  onChanged: _current && prefs.enabled
                      ? (value) => _mutate(
                          () => service.setSpokenRepliesEnabled(value),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  'game_companion.frequency'.tr,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in GameCompanionTalkativeness.values)
                      ChoiceChip(
                        label: Text(
                          'game_companion.frequency.${option.name}'.tr,
                        ),
                        selected: prefs.talkativeness == option,
                        onSelected: _current && prefs.enabled
                            ? (_) => _mutate(
                                () => service.setPreferences(
                                  service.preferences.copyWith(
                                    talkativeness: option,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'game_companion.hints'.tr,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in GameCompanionHintPolicy.values)
                      ChoiceChip(
                        label: Text('game_companion.hints.${option.name}'.tr),
                        selected: prefs.hintPolicy == option,
                        onSelected: _current && prefs.enabled
                            ? (_) => _mutate(
                                () => service.setPreferences(
                                  service.preferences.copyWith(
                                    hintPolicy: option,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('game_companion.vision'.tr),
                  subtitle: Text(
                    (captureSupported
                            ? 'game_companion.vision_hint'
                            : 'game_companion.vision_unsupported')
                        .tr,
                  ),
                  value: service.visualEnabled,
                  onChanged: _current && prefs.enabled && captureSupported
                      ? (value) =>
                            _mutate(() => service.setVisualEnabled(value))
                      : null,
                ),
                if (service.visualEnabled &&
                    status != null &&
                    status != GamePerceptionStatus.observing &&
                    status != GamePerceptionStatus.stopped)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'game_companion.vision_status.${status.name}'.tr,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('common.done'.tr),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Session revocation stays synchronous; only repainting its sibling controls
/// waits until the current player rebuild has finished.
class _GameCompanionRevisionBuilder extends StatefulWidget {
  const _GameCompanionRevisionBuilder({
    required this.revision,
    required this.builder,
  });

  final ValueListenable<int> revision;
  final WidgetBuilder builder;

  @override
  State<_GameCompanionRevisionBuilder> createState() =>
      _GameCompanionRevisionBuilderState();
}

class _GameCompanionRevisionBuilderState
    extends State<_GameCompanionRevisionBuilder> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.revision.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _GameCompanionRevisionBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.revision, widget.revision)) return;
    oldWidget.revision.removeListener(_changed);
    widget.revision.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.revision.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
