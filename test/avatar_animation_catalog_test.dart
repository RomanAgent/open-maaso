import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_animation_catalog.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/open_annie_animation_entries.dart';

void main() {
  const expectedIdleClipIds = [
    'idle',
    'idle_1',
    'idle_3456',
    'idle_look_around_1',
    'idle_nothing_to_do_201',
    'idle_shrug',
    'idle_turn_right_1',
  ];

  test('bundled animation catalog follows the Unity clip contract', () {
    final catalog = AvatarAnimationCatalog.bundled;

    expect(catalog.validate(), isEmpty);
    expect(catalog.byId.keys.take(7), expectedIdleClipIds);
    expect(catalog.clips, hasLength(70));

    for (final clip in catalog.clips) {
      expect(clip.source, AvatarAnimationSource.unityClip, reason: clip.id);
      expect(clip.backends, ['unity'], reason: clip.id);
      expect(clip.durationMs, greaterThan(0), reason: clip.id);
      expect(clip.fadeMs, greaterThanOrEqualTo(0), reason: clip.id);
    }
    for (final id in expectedIdleClipIds) {
      expect(catalog.byId[id]!.loop, isTrue, reason: id);
    }
  });

  test('catalog resolves aliases for Unity clips', () {
    final catalog = AvatarAnimationCatalog.bundled;

    expect(catalog.resolveClipId('ldle'), 'idle');
    expect(catalog.resolveClipId('default_idle'), 'idle');
    expect(catalog.resolveClipId('main_idle'), 'idle');
    expect(catalog.resolveClipId('shrug_idle'), 'idle_shrug');
    expect(catalog.resolveClipId('turn_right_idle'), 'idle_turn_right_1');
    expect(
      catalog.resolveClipId('nothing_to_do_idle'),
      'idle_nothing_to_do_201',
    );
    expect(catalog.resolveClipId('wave'), 'annie_wave');
    expect(catalog.resolveClipId('挥手'), 'annie_wave');
    expect(catalog.playableClipId('ldle', AvatarBackendKind.unity), 'idle');
    expect(
      catalog.playableClipId('shrug_idle', AvatarBackendKind.unity),
      'idle_shrug',
    );
    expect(
      catalog.playableClipId('custom_action', AvatarBackendKind.unity),
      'custom_action',
    );
  });

  test('catalog selects main idle by default and idle variants by intent', () {
    final catalog = AvatarAnimationCatalog.bundled;

    expect(
      catalog
          .selectClipForAct(
            backendKind: AvatarBackendKind.unity,
            gesture: 'none',
            mood: 'calm',
            posture: 'idle',
            intensity: 0.8,
          )
          ?.id,
      'idle',
    );
    expect(
      catalog
          .selectClipForAct(
            backendKind: AvatarBackendKind.unity,
            gesture: 'shrug',
            mood: 'calm',
            posture: 'idle',
            intensity: 0.8,
          )
          ?.id,
      'idle_shrug',
    );
    expect(
      catalog
          .selectClipForAct(
            backendKind: AvatarBackendKind.unity,
            gesture: 'wave',
            mood: 'happy',
            posture: 'none',
            intensity: 0.8,
          )
          ?.id,
      'annie_wave',
    );
  });

  test('all Open Annie entries are explicitly reachable with scoped IDs', () {
    final catalog = AvatarAnimationCatalog.bundled;
    final entries = openAnnieBundledClipEntries
        .map(AvatarAnimationClipSpec.fromJson)
        .toList();

    expect(entries, hasLength(63));
    expect(entries.where((clip) => clip.loop), hasLength(13));
    expect(entries.where((clip) => !clip.loop), hasLength(50));
    expect(entries.where((clip) => clip.layer == 'full_body'), hasLength(23));
    expect(entries.where((clip) => clip.layer == 'upper_body'), hasLength(40));
    for (final clip in entries) {
      expect(clip.id, startsWith('annie_'));
      expect(clip.tags, containsAll(['open_annie', 'cc0']));
      expect(catalog.playableClipId(clip.id, AvatarBackendKind.unity), clip.id);
      for (final alias in clip.aliases) {
        expect(
          catalog.playableClipId(alias, AvatarBackendKind.unity),
          clip.id,
          reason: alias,
        );
      }
    }
    expect(catalog.byId['annie_wave']!.durationMs, 2500);
    expect(catalog.byId['annie_dance']!.durationMs, 6267);
  });

  test('idle and talk-rest additions never replace default idle semantics', () {
    final catalog = AvatarAnimationCatalog.bundled;
    for (final clip in catalog.clips.where(
      (clip) =>
          clip.id.startsWith('annie_') &&
          (clip.tags.contains('idle') || clip.tags.contains('talk')),
    )) {
      expect(clip.semantics, isEmpty, reason: clip.id);
    }
    expect(
      catalog
          .selectClipForAct(
            backendKind: AvatarBackendKind.unity,
            gesture: 'none',
            mood: 'calm',
            posture: 'idle',
            intensity: 0.5,
          )
          ?.id,
      'idle',
    );
  });

  test(
    'explicit natural gestures select clips without suppressing posture',
    () {
      final catalog = AvatarAnimationCatalog.bundled;
      const expected = {
        'wave': 'annie_wave',
        'clap': 'annie_clap',
        'shrug': 'annie_shrug',
        'think': 'annie_think',
        'laugh': 'annie_laugh',
        'bow': 'annie_bow',
        'point_self': 'annie_point_self',
        'cheer': 'annie_excited_bounce',
        'dance': 'annie_dance',
        'explain': 'annie_g_offer_r',
        'palms_open': 'annie_g_open_both',
      };
      for (final entry in expected.entries) {
        expect(
          catalog
              .selectClipForAct(
                backendKind: AvatarBackendKind.unity,
                gesture: entry.key,
                mood: 'calm',
                posture: 'none',
                intensity: 0.65,
              )
              ?.id,
          entry.value,
          reason: entry.key,
        );
        for (final posture in ['walk', 'sit', 'desk_work', 'use_phone']) {
          expect(
            catalog.selectClipForAct(
              backendKind: AvatarBackendKind.unity,
              gesture: entry.key,
              mood: 'calm',
              posture: posture,
              intensity: 0.65,
            ),
            isNull,
            reason: '${entry.key} must not consume $posture',
          );
        }
      }
      // This pack has no authored nod/agree clip. Keep the existing primitive.
      for (final gesture in ['agree', 'nod']) {
        expect(
          catalog.selectClipForAct(
            backendKind: AvatarBackendKind.unity,
            gesture: gesture,
            mood: 'calm',
            posture: 'none',
            intensity: 0.65,
          ),
          isNull,
        );
      }
    },
  );
}
