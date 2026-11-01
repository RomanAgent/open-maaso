import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/avatar_interaction_coordinator.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';

void main() {
  test('maps every bounded region to a high-level Avatar intent', () async {
    final reactions = <AvatarReaction>[];
    final acts = <AvatarAct>[];
    final coordinator = AvatarInteractionCoordinator(
      applyReaction: (reaction) async {
        reactions.add(reaction);
        return _applied;
      },
      applyAct: (act) async {
        acts.add(act);
        return _applied;
      },
    );
    coordinator.activateGeneration(7);

    var timestamp = 10;
    for (final region in DesktopAvatarInteractionRegion.values) {
      await coordinator.handle(
        _interaction(region, generation: 7, timestampMs: timestamp++),
      );
    }

    expect(reactions, hasLength(2));
    expect(
      reactions
          .map(
            (reaction) => <String>[
              reaction.mood,
              reaction.gesture,
              reaction.gaze,
            ],
          )
          .toList(),
      <List<String>>[
        <String>['happy', 'nod', 'user'],
        <String>['calm', 'listen', 'user'],
      ],
    );
    expect(acts, hasLength(4));
    expect(
      acts.map((act) => <String>[act.mood, act.gesture, act.gaze]).toList(),
      <List<String>>[
        <String>['playful', 'look_away', 'left'],
        <String>['playful', 'look_away', 'right'],
        <String>['excited', 'jump', 'user'],
        <String>['happy', 'wave', 'user'],
      ],
    );
    expect(<double>[
      ...reactions.map((reaction) => reaction.intensity),
      ...acts.map((act) => act.intensity),
    ], everyElement(inInclusiveRange(0, 1)));
  });

  test(
    'drops inactive, wrong-generation, duplicate, and stale events',
    () async {
      final appliedRegions = <DesktopAvatarInteractionRegion>[];
      final coordinator = AvatarInteractionCoordinator(
        applyReaction: (reaction) async {
          appliedRegions.add(DesktopAvatarInteractionRegion.head);
          return _applied;
        },
        applyAct: (_) async => _applied,
      );
      final first = _interaction(
        DesktopAvatarInteractionRegion.head,
        generation: 3,
        timestampMs: 20,
      );

      expect(await coordinator.handle(first), isNull);
      coordinator.activateGeneration(3);
      expect(await coordinator.handle(first), same(_applied));
      expect(await coordinator.handle(first), isNull);
      expect(
        await coordinator.handle(
          _interaction(
            DesktopAvatarInteractionRegion.head,
            generation: 3,
            timestampMs: 19,
          ),
        ),
        isNull,
      );
      expect(
        await coordinator.handle(
          _interaction(
            DesktopAvatarInteractionRegion.head,
            generation: 4,
            timestampMs: 21,
          ),
        ),
        isNull,
      );
      coordinator.deactivate();
      expect(
        await coordinator.handle(
          _interaction(
            DesktopAvatarInteractionRegion.head,
            generation: 3,
            timestampMs: 22,
          ),
        ),
        isNull,
      );
      expect(appliedRegions, <DesktopAvatarInteractionRegion>[
        DesktopAvatarInteractionRegion.head,
      ]);
    },
  );

  test(
    'serializes interactions and fences queued work on deactivate',
    () async {
      final firstGate = Completer<void>();
      final firstStarted = Completer<void>();
      final calls = <String>[];
      final coordinator = AvatarInteractionCoordinator(
        applyReaction: (reaction) async {
          calls.add(reaction.gesture);
          firstStarted.complete();
          await firstGate.future;
          return _applied;
        },
        applyAct: (act) async {
          calls.add(act.gesture);
          return _applied;
        },
      );
      coordinator.activateGeneration(9);

      final first = coordinator.handle(
        _interaction(
          DesktopAvatarInteractionRegion.head,
          generation: 9,
          timestampMs: 1,
        ),
      );
      final second = coordinator.handle(
        _interaction(
          DesktopAvatarInteractionRegion.feet,
          generation: 9,
          timestampMs: 2,
        ),
      );
      await firstStarted.future;
      expect(calls, <String>['nod']);

      coordinator.deactivate();
      firstGate.complete();

      expect(await first, same(_applied));
      expect(await second, isNull);
      expect(calls, <String>['nod']);
    },
  );
}

const AvatarBehaviorResult _applied = AvatarBehaviorResult(
  applied: true,
  reason: 'test',
);

DesktopAvatarInteractionV1 _interaction(
  DesktopAvatarInteractionRegion region, {
  required int generation,
  required int timestampMs,
}) => DesktopAvatarInteractionV1(
  normalizedX: 0.5,
  normalizedY: 0.5,
  region: region,
  generation: generation,
  timestampMs: timestampMs,
);
