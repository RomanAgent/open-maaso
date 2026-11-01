import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/projector_media_session.dart';

void main() {
  test('bare subject resolves as an online projector image query', () {
    final session = ProjectorMediaSession(ttl: const Duration(minutes: 2))
      ..markAwaitingMediaSource(now: DateTime(2026, 6, 22, 12));

    final resolution = session.resolveUserText(
      'silly cat',
      now: DateTime(2026, 6, 22, 12, 1),
    );

    expect(resolution.kind, ProjectorMediaResolutionKind.onlineImage);
    expect(resolution.imageQuery, 'silly cat');
    expect(resolution.shouldSearch, isTrue);
    expect(resolution.shouldUseGallery, isFalse);
    expect(resolution.promptBlock, contains('image-search host tool'));
    expect(
      resolution.promptBlock,
      contains('skill_bleyoturetoys_projectortransferimage'),
    );
  });

  test('gallery choice resolves without web search', () {
    final session = ProjectorMediaSession()
      ..observeAssistantText(
        'Connected. Want to use a photo from your gallery or find one online?',
      );

    final resolution = session.resolveUserText('from gallery');

    expect(resolution.kind, ProjectorMediaResolutionKind.gallery);
    expect(resolution.shouldUseGallery, isTrue);
    expect(resolution.shouldSearch, isFalse);
    expect(
      resolution.promptBlock,
      contains('skill_bleyoturetoys_projectorsendgallery'),
    );
  });

  test('expired media prompt does not capture ordinary text', () {
    final session = ProjectorMediaSession(ttl: const Duration(seconds: 30))
      ..markAwaitingMediaSource(now: DateTime(2026, 6, 22, 12));

    final resolution = session.resolveUserText(
      'cat',
      now: DateTime(2026, 6, 22, 12, 1),
    );

    expect(resolution.kind, ProjectorMediaResolutionKind.none);
    expect(resolution.isProjectorFollowUp, isFalse);
  });

  test('surface words are not stolen by projector media session', () {
    final session = ProjectorMediaSession()..markAwaitingMediaSource();

    final resolution = session.resolveUserText('make me a photo album');

    expect(resolution.kind, ProjectorMediaResolutionKind.none);
    expect(resolution.isProjectorFollowUp, isFalse);
  });

  test('ordinary command closes the pending projector choice', () {
    final session = ProjectorMediaSession()..markAwaitingMediaSource();

    final ordinary = session.resolveUserText('say hello');
    final laterSubject = session.resolveUserText('silly cat');

    expect(ordinary, same(ProjectorMediaResolution.none));
    expect(session.isAwaitingMediaSource, isFalse);
    expect(laterSubject, same(ProjectorMediaResolution.none));
  });

  test('a consumed projector choice is one-shot', () {
    final session = ProjectorMediaSession()..markAwaitingMediaSource();

    final related = session.resolveUserText('silly cat');
    final later = session.resolveUserText('say hello');

    expect(related.kind, ProjectorMediaResolutionKind.onlineImage);
    expect(related.imageQuery, 'silly cat');
    expect(session.isAwaitingMediaSource, isFalse);
    expect(later, same(ProjectorMediaResolution.none));
  });

  test('projector prompt follows the explicit runtime locale', () {
    const resolution = ProjectorMediaResolution(
      kind: ProjectorMediaResolutionKind.onlineImage,
      imageQuery: '小狗',
    );

    final zh = resolution.promptBlockFor(AppLocale.zh);
    expect(zh, contains('用户想为投影仪使用在线图片'));
    expect(zh, contains('skill_bleyoturetoys_projectortransferimage'));
    expect(zh, isNot(contains('user wants an online image')));
  });
}
