import 'dart:async';

import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';

typedef AvatarInteractionApplyReaction =
    Future<AvatarBehaviorResult> Function(AvatarReaction reaction);
typedef AvatarInteractionApplyAct =
    Future<AvatarBehaviorResult> Function(AvatarAct act);

/// Serializes native desktop-pet taps into existing high-level Avatar intents.
final class AvatarInteractionCoordinator {
  AvatarInteractionCoordinator({
    AvatarBehaviorDirector? director,
    AvatarInteractionApplyReaction? applyReaction,
    AvatarInteractionApplyAct? applyAct,
  }) {
    final behaviorDirector = director ?? AvatarBehaviorDirector();
    _applyReaction = applyReaction ?? behaviorDirector.applyReaction;
    _applyAct = applyAct ?? behaviorDirector.applyAct;
  }

  late final AvatarInteractionApplyReaction _applyReaction;
  late final AvatarInteractionApplyAct _applyAct;
  Future<void> _queue = Future<void>.value();
  int? _activeGeneration;
  int? _lastTimestampMs;
  int _activationEpoch = 0;

  int? get activeGeneration => _activeGeneration;

  void activateGeneration(int generation) {
    if (generation < DesktopAvatarInteractionV1.minimumGeneration ||
        generation > DesktopAvatarInteractionV1.maximumGeneration) {
      throw ArgumentError.value(generation, 'generation');
    }
    if (_activeGeneration == generation) return;
    _activationEpoch++;
    _activeGeneration = generation;
    _lastTimestampMs = null;
  }

  void deactivate() {
    _activationEpoch++;
    _activeGeneration = null;
    _lastTimestampMs = null;
  }

  Future<AvatarBehaviorResult?> handle(DesktopAvatarInteractionV1 interaction) {
    if (interaction.type != DesktopAvatarInteractionType.tap ||
        interaction.generation != _activeGeneration) {
      return Future<AvatarBehaviorResult?>.value();
    }
    final lastTimestampMs = _lastTimestampMs;
    if (lastTimestampMs != null && interaction.timestampMs <= lastTimestampMs) {
      return Future<AvatarBehaviorResult?>.value();
    }
    _lastTimestampMs = interaction.timestampMs;

    final activationEpoch = _activationEpoch;
    final operation = _queue.then<AvatarBehaviorResult?>((_) {
      if (activationEpoch != _activationEpoch ||
          interaction.generation != _activeGeneration) {
        return null;
      }
      return _applyInteraction(interaction.region);
    });
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<AvatarBehaviorResult> _applyInteraction(
    DesktopAvatarInteractionRegion region,
  ) {
    return switch (region) {
      DesktopAvatarInteractionRegion.head => _applyReaction(
        const AvatarReaction(
          mood: 'happy',
          gesture: 'nod',
          gaze: 'user',
          style: 'subtle',
          intensity: 0.48,
          durationMs: 900,
        ),
      ),
      DesktopAvatarInteractionRegion.torso => _applyReaction(
        const AvatarReaction(
          mood: 'calm',
          gesture: 'listen',
          gaze: 'user',
          style: 'subtle',
          intensity: 0.4,
          durationMs: 900,
        ),
      ),
      DesktopAvatarInteractionRegion.leftSide => _applyAct(
        const AvatarAct(
          mood: 'playful',
          gesture: 'look_away',
          gaze: 'left',
          style: 'subtle',
          intensity: 0.42,
          durationMs: 900,
        ),
      ),
      DesktopAvatarInteractionRegion.rightSide => _applyAct(
        const AvatarAct(
          mood: 'playful',
          gesture: 'look_away',
          gaze: 'right',
          style: 'subtle',
          intensity: 0.42,
          durationMs: 900,
        ),
      ),
      DesktopAvatarInteractionRegion.feet => _applyAct(
        const AvatarAct(
          mood: 'excited',
          gesture: 'jump',
          gaze: 'user',
          style: 'subtle',
          intensity: 0.5,
          durationMs: 950,
        ),
      ),
      DesktopAvatarInteractionRegion.avatar => _applyAct(
        const AvatarAct(
          mood: 'happy',
          gesture: 'wave',
          gaze: 'user',
          style: 'subtle',
          intensity: 0.45,
          durationMs: 950,
        ),
      ),
    };
  }
}
