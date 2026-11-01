import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_orb.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

/// A full-screen, pass-through HUD designed to sit above the app navigator.
///
/// Only the bottom-left voice control is interactive. The visible status is
/// wrapped in [IgnorePointer], so it never competes with page gestures.
class AgentControlHud extends StatefulWidget {
  const AgentControlHud({
    required this.coordinator,
    this.speakingEvents,
    this.agentId,
    this.onOrbTap,
    this.showOrb = true,
    this.orbSize = 48,
    this.orbMargin = const EdgeInsets.only(left: 16, bottom: 16),
    this.orbSemanticLabel = 'agent_control.voice_control',
    this.reducedMotion,
    super.key,
  });

  static const Key hudKey = ValueKey<String>('agent-control-hud');
  static const Key statusIgnorePointerKey = ValueKey<String>(
    'agent-control-hud-status-ignore-pointer',
  );
  static const Key statusSemanticsKey = ValueKey<String>(
    'agent-control-hud-status-semantics',
  );
  static const Key statusOpacityKey = ValueKey<String>(
    'agent-control-hud-status-opacity',
  );
  static const Key statusChipKey = ValueKey<String>(
    'agent-control-hud-status-chip',
  );
  static const Key orbSemanticsKey = ValueKey<String>(
    'agent-control-hud-orb-semantics',
  );
  static const Key orbTapTargetKey = ValueKey<String>(
    'agent-control-hud-orb-tap-target',
  );

  final AgentUiControlCoordinator coordinator;
  final Stream<SpeakingStatusEvent>? speakingEvents;
  final String? agentId;
  final VoidCallback? onOrbTap;
  final bool showOrb;
  final double orbSize;
  final EdgeInsets orbMargin;
  final String orbSemanticLabel;

  /// Overrides the platform preference in tests or an embedding shell.
  final bool? reducedMotion;

  @override
  State<AgentControlHud> createState() => _AgentControlHudState();
}

class _AgentControlHudState extends State<AgentControlHud> {
  late AgentUiControlSnapshot _snapshot;
  StreamSubscription<AgentUiControlSnapshot>? _controlSubscription;
  StreamSubscription<SpeakingStatusEvent>? _speakingSubscription;
  bool _isSpeaking = false;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _bindCoordinator();
    _bindSpeakingEvents();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant AgentControlHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, widget.coordinator)) {
      unawaited(_controlSubscription?.cancel());
      _bindCoordinator();
    }
    if (!identical(oldWidget.speakingEvents, widget.speakingEvents) ||
        oldWidget.agentId != widget.agentId) {
      unawaited(_speakingSubscription?.cancel());
      _isSpeaking = false;
      _bindSpeakingEvents();
    }
    if (oldWidget.reducedMotion != widget.reducedMotion) {
      _syncMotionPreference();
    }
  }

  @override
  void dispose() {
    unawaited(_controlSubscription?.cancel());
    unawaited(_speakingSubscription?.cancel());
    super.dispose();
  }

  void _bindCoordinator() {
    _snapshot = widget.coordinator.snapshot;
    _controlSubscription = widget.coordinator.changes.listen((snapshot) {
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    });
  }

  void _bindSpeakingEvents() {
    final events =
        widget.speakingEvents ?? EventBus().on<SpeakingStatusEvent>();
    _speakingSubscription = events.listen((event) {
      final expectedAgentId = widget.agentId;
      if (expectedAgentId != null &&
          event.agentId != null &&
          event.agentId != expectedAgentId) {
        return;
      }
      if (_isSpeaking == event.isSpeaking || !mounted) return;
      setState(() => _isSpeaking = event.isSpeaking);
    });
  }

  void _syncMotionPreference() {
    _reducedMotion =
        widget.reducedMotion ??
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Stack(
      key: AgentControlHud.hudKey,
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            key: AgentControlHud.statusIgnorePointerKey,
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Align(
                alignment: Alignment.topCenter,
                child: ExcludeSemantics(
                  excluding: !_showsControlStatus,
                  child: Semantics(
                    key: AgentControlHud.statusSemanticsKey,
                    container: true,
                    liveRegion: true,
                    label: 'agent_control.active_label'.tr,
                    value: _visibleControlStatus,
                    child: AnimatedOpacity(
                      key: AgentControlHud.statusOpacityKey,
                      opacity: _showsControlStatus ? 1 : 0,
                      duration: _reducedMotion
                          ? Duration.zero
                          : MaasoGlassTheme.motionFast,
                      curve: Curves.easeOutCubic,
                      child: _buildStatusChip(glass: glass),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.showOrb)
          Positioned.fill(
            child: SafeArea(
              minimum: widget.orbMargin,
              child: Align(alignment: Alignment.bottomLeft, child: _buildOrb()),
            ),
          ),
      ],
    );
  }

  Widget _buildOrb() {
    final size = math.max(widget.orbSize, MaasoGlassTheme.controlTarget);
    final orbSemanticLabel = widget.orbSemanticLabel.tr;
    final phase = _isSpeaking
        ? VoiceOrbPhase.speaking
        : switch (_snapshot.phase) {
            AgentUiControlPhase.navigating ||
            AgentUiControlPhase.operating => VoiceOrbPhase.thinking,
            _ => VoiceOrbPhase.listening,
          };
    final amplitude = _isSpeaking
        ? 0.72
        : switch (_snapshot.phase) {
            AgentUiControlPhase.navigating ||
            AgentUiControlPhase.operating => 0.30,
            _ => 0.12,
          };

    return Semantics(
      key: AgentControlHud.orbSemanticsKey,
      container: true,
      liveRegion: true,
      button: widget.onOrbTap != null,
      label: orbSemanticLabel,
      value: _semanticStatus,
      onTap: widget.onOrbTap,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkResponse(
          key: AgentControlHud.orbTapTargetKey,
          onTap: widget.onOrbTap,
          containedInkWell: true,
          highlightShape: BoxShape.circle,
          excludeFromSemantics: true,
          child: SizedBox.square(
            dimension: size,
            child: ExcludeSemantics(
              child: AppGlassVoiceOrb(
                phase: phase,
                amplitude: amplitude,
                reducedMotion: _reducedMotion,
                semanticLabel: orbSemanticLabel,
                size: size,
                showProjectedHalo: false,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip({required MaasoGlassTheme glass}) {
    return AppGlassSurface(
      key: AgentControlHud.statusChipKey,
      role: AppGlassSurfaceRole.transient,
      cornerRadius: MaasoGlassTheme.capsuleRadius,
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.smart_toy_outlined, size: 18, color: glass.accentText),
          const SizedBox(width: MaasoGlassTheme.spaceSm),
          Flexible(
            child: Text(
              _visibleControlStatus,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: glass.foregroundPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _showsControlStatus => switch (_snapshot.phase) {
    AgentUiControlPhase.awaitingConsent ||
    AgentUiControlPhase.navigating ||
    AgentUiControlPhase.operating ||
    AgentUiControlPhase.pausedByUser => true,
    _ => false,
  };

  String get _visibleControlStatus => _semanticStatus;

  String get _semanticStatus {
    if (_isSpeaking) return 'agent_control.status.speaking'.tr;
    return switch (_snapshot.phase) {
      AgentUiControlPhase.idle => 'agent_control.status.ready'.tr,
      AgentUiControlPhase.awaitingConsent =>
        'agent_control.status.waiting_permission'.tr,
      AgentUiControlPhase.navigating => 'agent_control.status.navigating'.tr,
      AgentUiControlPhase.operating => 'agent_control.status.operating'.tr,
      AgentUiControlPhase.pausedByUser => 'agent_control.status.paused'.tr,
      AgentUiControlPhase.completed => 'agent_control.status.completed'.tr,
      AgentUiControlPhase.failed => 'agent_control.status.failed'.tr,
    };
  }
}
