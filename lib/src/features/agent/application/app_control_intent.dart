import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

enum AppOperationIntentKind {
  none,
  navigation,
  editorialWriting,
  informationalWriting,
}

extension AppOperationIntentKindX on AppOperationIntentKind {
  bool get usesAppControl => this == AppOperationIntentKind.navigation;

  bool get suppressesGeneratedSurface =>
      usesAppControl ||
      this == AppOperationIntentKind.editorialWriting ||
      this == AppOperationIntentKind.informationalWriting;
}

const _genericControlCues = <String>[
  '帮我操作',
  '自动填写',
  '自动输入',
  '点击按钮',
  'control the app',
  'operate the app',
  'fill in the app',
  'type into the app',
];

const _writingActionCues = <String>[
  '帮我写',
  '写一篇',
  '写篇',
  '起标题',
  '列大纲',
  '写正文',
  '准备一篇',
  '创作一篇',
  '放进创作页面',
  '放到创作页面',
  '填进创作页面',
  '填写创作页面',
  'write me',
  'help me write',
  'draft an',
  'draft a',
  'prepare an article',
  'prepare a blog',
];

const _editorialContentCues = <String>[
  '文章',
  '标题',
  '大纲',
  '正文',
  '专栏',
  '新闻稿',
  '故事',
  '小说',
  '公众号',
  '博客',
  '文案',
  'article',
  'blog',
  'newsletter',
  'story',
  'outline',
  'body',
  'headline',
];

const _informationalWritingCues = <String>[
  '要多久',
  '步骤是什么',
  '用什么软件',
  '怎么写',
  '如何写',
  '写作方法',
  '写作步骤',
  '难不难',
  '成本是多少',
  'how to write',
  'how long does it take',
  'steps to write',
  'what software',
  'explain how to write',
];

AppOperationIntentKind classifyAppOperationIntent(String text) {
  final lower = text.trim().toLowerCase();
  if (lower.isEmpty) return AppOperationIntentKind.none;

  // Controls, navigation and writing inside a requested game/applet describe
  // the product to build. They do not authorize operating the host app.
  if (SurfaceCreationAuthority.experienceTypeFor(
        text: text,
        interactiveHint: true,
        surfaceIntent: SurfaceIntent.classify(text),
      ) !=
      null) {
    return AppOperationIntentKind.none;
  }

  final informationalWriting = _containsAny(lower, _informationalWritingCues);
  final editorialRequest =
      _containsAny(lower, _writingActionCues) &&
      (_containsAny(lower, _editorialContentCues) ||
          lower.contains('写一篇') ||
          lower.contains('write me'));
  if (informationalWriting &&
      (_containsAny(lower, _writingActionCues) ||
          _containsAny(lower, _editorialContentCues))) {
    return AppOperationIntentKind.informationalWriting;
  }
  if (editorialRequest) {
    return AppOperationIntentKind.editorialWriting;
  }

  if (_containsAny(lower, _genericControlCues)) {
    return AppOperationIntentKind.navigation;
  }
  if (!looksLikeNavigationIntent(lower)) {
    return AppOperationIntentKind.none;
  }
  for (final destination in AppRouteCatalog.destinations) {
    if (destination.id == lower ||
        destination.keywords.any(
          (keyword) => lower.contains(keyword.toLowerCase()),
        ) ||
        destination.variants.any(
          (variant) => variant.keywords.any(
            (keyword) => lower.contains(keyword.toLowerCase()),
          ),
        )) {
      return AppOperationIntentKind.navigation;
    }
  }
  return AppOperationIntentKind.none;
}

/// True only for explicit navigation or visible page-operation requests.
///
/// Ordinary writing stays in the conversation rather than operating a page.
bool looksLikeAppControlIntent(String text) =>
    classifyAppOperationIntent(text).usesAppControl;

bool _containsAny(String haystack, Iterable<String> needles) {
  for (final needle in needles) {
    if (haystack.contains(needle)) return true;
  }
  return false;
}
