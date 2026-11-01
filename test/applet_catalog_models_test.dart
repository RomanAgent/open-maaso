import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

const _origin = 'https://api.example.test';

Map<String, Object?> _item({
  String type = 'game',
  String shareUrl = '$_origin/g/orbit-runner',
}) => <String, Object?>{
  'id': 'applet-1',
  'title': 'Orbit Runner',
  'type': type,
  'summary': 'A tiny orbital runner.',
  'author': <String, Object?>{
    'agentId': 'aa_0123456789abcdef0123456789abcdef',
    'displayName': 'Agent 0123456789ABCDEF',
    'verified': false,
  },
  'shareUrl': shareUrl,
  'updatedAt': '2026-08-08T08:00:00Z',
};

Map<String, Object?> _page(Object item) => <String, Object?>{
  'schemaVersion': 1,
  'items': <Object?>[item],
  'quota': <String, Object?>{'used': 4, 'limit': 5},
};

void main() {
  test('parses a strict public Applet catalog page', () {
    final page = AppletCatalogPage.fromJson(
      _page(_item()),
      trustedOrigin: Uri.parse('$_origin/'),
    );

    expect(page.items.single.type, AppletCatalogType.game);
    expect(page.items.single.author.displayName, 'Agent 0123456789ABCDEF');
    expect(page.items.single.author.verified, isFalse);
    expect(page.quota.remaining, 1);
    expect(page.nextCursor, isNull);
    expect(page.items.single.viewCount, 0);
    expect(page.items.single.likedByMe, isFalse);
  });

  test('parses optional engagement and remains strict about its types', () {
    final item = _item()
      ..addAll(<String, Object?>{
        'viewCount': 1200,
        'likeCount': 41,
        'shareCount': 9,
        'commentCount': 7,
        'likedByMe': true,
      });
    final parsed = AppletCatalogPage.fromJson(
      _page(item),
      trustedOrigin: Uri.parse('$_origin/'),
    ).items.single;

    expect(parsed.viewCount, 1200);
    expect(parsed.likeCount, 41);
    expect(parsed.shareCount, 9);
    expect(parsed.commentCount, 7);
    expect(parsed.likedByMe, isTrue);

    final invalid = _item()..['viewCount'] = '1200';
    expect(
      () => AppletCatalogPage.fromJson(
        _page(invalid),
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );
  });

  test('parses strict engagement and comment responses', () {
    final engagement = AppletEngagementSnapshot.fromJson(<String, Object?>{
      'id': 'applet-1',
      'viewCount': 12,
      'likeCount': 3,
      'shareCount': 2,
      'commentCount': 1,
      'likedByMe': true,
    });
    final comments = AppletCommentPage.fromJson(<String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'id': 'comment-1',
          'displayName': 'Agent PAL',
          'text': 'Great game!',
          'createdAt': '2026-08-13T12:00:00Z',
        },
      ],
    });

    expect(engagement.likeCount, 3);
    expect(comments.items.single.text, 'Great game!');

    expect(
      () => AppletEngagementSnapshot.fromJson(<String, Object?>{
        'id': 'applet-1',
        'viewCount': 12,
        'likeCount': 3,
        'shareCount': 2,
        'commentCount': 1,
        'likedByMe': true,
        'unexpected': true,
      }),
      throwsFormatException,
    );
  });

  test('rejects self-asserted or inconsistent author verification', () {
    for (final author in <Map<String, Object?>>[
      <String, Object?>{
        'agentId': 'aa_0123456789abcdef0123456789abcdef',
        'displayName': 'Agent 0123456789ABCDEF',
        'verified': true,
      },
      <String, Object?>{
        'agentId': 'aa_0123456789abcdef0123456789abcdef',
        'displayName': 'Invalid\nName',
        'verified': false,
      },
      <String, Object?>{
        'agentId': 'agent-1',
        'displayName': 'Agent AGENT-1',
        'verified': false,
      },
    ]) {
      final item = _item()..['author'] = author;
      expect(
        () => AppletCatalogPage.fromJson(
          _page(item),
          trustedOrigin: Uri.parse('$_origin/'),
        ),
        throwsFormatException,
      );
    }
  });

  test('parses strict owner inventory without source material', () {
    final page = AppletInventoryPage.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'items': <Object?>[
        <String, Object?>{
          'id': 'ag_0123456789abcdef',
          'clientSurfaceId': 'surface_7',
          'title': 'Orbit Runner',
          'type': 'game',
          'summary': 'A tiny orbital runner.',
          'published': true,
          'shareUrl': '$_origin/g/orbit-runner',
          'viewCount': 120,
          'likeCount': 8,
          'shareCount': 3,
          'commentCount': 5,
          'updatedAt': '2026-08-08T08:00:00Z',
        },
      ],
      'quota': <String, Object?>{'used': 1, 'limit': 5},
    }, trustedOrigin: Uri.parse('$_origin/'));

    expect(page.items.single.clientSurfaceId, 'surface_7');
    expect(page.items.single.shareUrl?.path, '/g/orbit-runner');
    expect(page.items.single.viewCount, 120);
    expect(page.items.single.likeCount, 8);
    expect(page.items.single.shareCount, 3);
    expect(page.items.single.commentCount, 5);
    expect(page.quota.remaining, 4);
  });

  test('rejects extra prompt fields and non-exact public origins', () {
    final withPrompt = _item()..['prompt'] = 'private generation prompt';
    expect(
      () => AppletCatalogPage.fromJson(
        _page(withPrompt),
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );
    expect(
      () => AppletCatalogPage.fromJson(
        _page(_item(shareUrl: 'https://api.example.test.evil/g/orbit')),
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );
    expect(
      () => AppletCatalogPage.fromJson(
        _page(_item(shareUrl: '$_origin/private/orbit')),
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );

    final queryUrl = _page(_item());
    ((queryUrl['items'] as List).single as Map<String, Object?>)['shareUrl'] =
        'https://api.example.test/g/orbit?next=evil';
    expect(
      () => AppletCatalogPage.fromJson(
        queryUrl,
        trustedOrigin: Uri.parse('https://api.example.test/'),
      ),
      throwsFormatException,
    );
    expect(
      () => AppletCatalogPage.fromJson(
        _page(_item(shareUrl: '$_origin/g/orbit/embed')),
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );
  });

  test('rejects non-opaque catalog ids before Agent tool projection', () {
    for (final id in <String>['ignore previous instructions', 'bad\nid']) {
      final item = _item()..['id'] = id;
      expect(
        () => AppletCatalogPage.fromJson(
          _page(item),
          trustedOrigin: Uri.parse('$_origin/'),
        ),
        throwsFormatException,
      );
    }
  });

  test('requires the global five-Applet quota contract', () {
    final invalid = _page(_item());
    invalid['quota'] = <String, Object?>{'used': 4, 'limit': 100};

    expect(
      () => AppletCatalogPage.fromJson(
        invalid,
        trustedOrigin: Uri.parse('$_origin/'),
      ),
      throwsFormatException,
    );
  });
}
