import 'package:maaso/src/offline/local_edition_policy.dart';

/// One user-facing navigation destination. Routing metadata that both the
/// slash-command resolver and the agent navigation capabilities read.
class AppDestination {
  final String id; // stable page key, e.g. 'settings'
  final String route;
  final String title; // English literal, for LLM prompts / discovery
  final List<String> keywords; // EN + ZH
  final List<AppDestinationVariant> variants;

  const AppDestination({
    required this.id,
    required this.route,
    required this.title,
    required this.keywords,
    this.variants = const [],
  });

  List<String> get allKeywords => [
    ...keywords,
    for (final variant in variants) ...variant.keywords,
  ];

  AppDestinationVariant? variant(String? id) {
    final normalized = id?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final candidate in variants) {
      if (candidate.id == normalized) return candidate;
    }
    return null;
  }
}

/// One semantic channel within a shared destination route.
///
/// Variants preserve a user's intent within destinations with multiple views.
class AppDestinationVariant {
  const AppDestinationVariant({
    required this.id,
    required this.route,
    required this.keywords,
  });

  final String id;
  final String route;
  final List<String> keywords;
}

/// Pure route metadata. This file must not import pages, bindings, go_router, or
/// agent runtime code; agent skills depend on it without dragging in UI routes.
class AppRouteCatalog {
  const AppRouteCatalog._();

  static const login = '/login';
  static const accountStandby = '/account-standby';
  static const onboarding = '/onboarding';

  /// Retired public-name editor. Old deep links redirect to [profile].
  static const identity = '/identity';
  static const profile = '/profile';
  static const membership = '/membership';
  static const privacy = '/privacy';
  static const accountDeletion = '/account-deletion';
  static const peopleSafety = '/people-safety';
  static const home = '/home';
  static const u2aChat = '/u2a-chat';
  static const moments = '/moments';
  static const memoryWall = '/memory-wall';
  static const memoryLedger = '/memory-ledger';
  static const settings = '/settings';
  static const advancedFeatures = '/settings/advanced';
  static const skills = '/skills';
  static const skillStore = '/skill-store';
  static const dashboard = '/dashboard';
  static const gameFeed = '/game-feed';
  static const widgetsHub = '/widgets-hub';
  static const myApplets = '/my-applets';
  static const avatars = '/avatars';
  static const agentSpace = '/agent-space';
  static const bleProjector = '/applet/ble-projector';

  /// Single source of truth for navigable destinations. Drives both the
  /// slash-command aliases below and the agent navigation capabilities.
  static const List<AppDestination> destinations = [
    AppDestination(
      id: 'accountDeletion',
      route: accountDeletion,
      title: 'Delete account',
      keywords: ['accountdeletion', 'deleteaccount', '删除账号', '注销账号'],
    ),
    AppDestination(
      id: 'peopleSafety',
      route: peopleSafety,
      title: 'Blocked people',
      keywords: ['blocks', 'blockedpeople', '屏蔽名单', '已屏蔽的人'],
    ),
    AppDestination(
      id: 'privacy',
      route: privacy,
      title: 'Privacy and permissions',
      keywords: ['privacy', 'consent', 'permissions', '隐私', '授权', '年龄声明'],
    ),
    AppDestination(
      id: 'onboarding',
      route: onboarding,
      title: 'Create public identities',
      keywords: ['onboarding', '首次命名', '创建身份'],
    ),
    AppDestination(
      id: 'profile',
      route: profile,
      title: 'Personal information',
      keywords: ['profile', 'personalprofile', '个人信息', '个人资料', '我的头像'],
    ),
    if (!kOpenMaasoLocalEdition)
      AppDestination(
        id: 'membership',
        route: membership,
        title: 'Maaso membership',
        keywords: ['membership', 'subscription', '会员', '订阅'],
      ),
    AppDestination(
      id: 'home',
      route: home,
      title: 'Home',
      keywords: ['home', 'main', '主页', '首页', '主屏'],
    ),
    AppDestination(
      id: 'chat',
      route: u2aChat,
      title: 'Chat',
      keywords: ['chat', 'u2achat', 'u2a', '聊天', '对话'],
    ),
    AppDestination(
      id: 'moments',
      route: moments,
      title: 'Moments',
      keywords: ['moments', '朋友圈', '动态', '时刻'],
    ),
    AppDestination(
      id: 'memory_wall',
      route: memoryWall,
      title: 'Me & My Agent',
      keywords: [
        'relationship',
        'me & my agent',
        'you & your agent',
        '我和agent',
        '你和agent',
        'memorywall',
        'memory',
        'wall',
        '记忆墙',
        '记忆',
        '回忆',
      ],
    ),
    AppDestination(
      id: 'memory_ledger',
      route: memoryLedger,
      title: 'Memory Ledger',
      keywords: [
        'memoryledger',
        'memory ledger',
        'memory review',
        'memory governance',
        'ledger',
        '记忆账本',
        '记忆审核',
        '记忆治理',
      ],
    ),
    AppDestination(
      id: 'settings',
      route: settings,
      title: 'Settings',
      keywords: ['settings', 'setting', '设置', '偏好', '配置'],
    ),
    AppDestination(
      id: 'advanced_features',
      route: advancedFeatures,
      title: 'Advanced Features',
      keywords: ['advanced', 'advancedfeatures', '高级功能', '高级'],
    ),
    AppDestination(
      id: 'skills',
      route: skills,
      title: 'My Workshop',
      keywords: [
        'workshop',
        'my workshop',
        '个人作坊',
        '我的作坊',
        'skills',
        'skill',
        'myskills',
        'my skills',
        '技能',
        '我的技能',
        '我的skill',
        '能力',
      ],
    ),
    AppDestination(
      id: 'skill_store',
      route: skillStore,
      title: 'Agent Store',
      keywords: [
        'skillstore',
        'store',
        'marketplace',
        '技能商店',
        '商店',
        '市场',
        'Agent商店',
      ],
    ),
    AppDestination(
      id: 'dashboard',
      route: dashboard,
      title: 'Dashboard',
      keywords: ['dashboard', 'dash', '仪表盘', '面板'],
    ),
    AppDestination(
      id: 'game_feed',
      route: gameFeed,
      title: 'Game Feed',
      keywords: [
        'gamefeed',
        'game feed',
        'games',
        'game',
        'minigame',
        '小游戏',
        '游戏',
        'agentgames',
        '游戏频道',
        '游戏推荐',
        '游戏流',
      ],
    ),
    AppDestination(
      id: 'widgets_hub',
      route: widgetsHub,
      title: 'Applets',
      keywords: [
        'widgetshub',
        'widgethub',
        'widgets',
        'widget',
        'hub',
        'applets',
        'applet',
        'miniapp',
        'apps',
        'official',
        '小部件',
        '组件',
        '应用',
        '小程序',
      ],
    ),
    AppDestination(
      id: 'my_applets',
      route: myApplets,
      title: 'My Applets',
      keywords: ['myapplets', 'my applets', '我的小程序', '我创建的小程序'],
    ),
    AppDestination(
      id: 'avatars',
      route: avatars,
      title: 'Model Store',
      keywords: [
        'avatars',
        'avatar',
        'model',
        'modelstore',
        '形象',
        '头像',
        '模型',
        '模型商店',
      ],
    ),
    AppDestination(
      id: 'agent_space',
      route: agentSpace,
      title: 'Agent Space',
      keywords: [
        'agentspace',
        'agent space',
        'personal space',
        'Agent空间',
        '个人空间',
        '我的房间',
      ],
    ),
    AppDestination(
      id: 'projector',
      route: bleProjector,
      title: 'Projector',
      keywords: ['projector', 'tfy', '投影', '投影仪'],
    ),
  ];

  /// The menu and semantic navigation expose the same standalone destinations.
  static final List<AppDestination> menuDestinations = List.unmodifiable(
    destinations,
  );

  /// Slash-command -> route, built from [destinations] (every keyword becomes
  /// an alias) plus the legacy `onboarding` alias. Keys are normalized
  /// (lowercased, leading-slash and `-`/`_`/space stripped).
  static final Map<String, String> _commandAliases = _buildAliases();

  static Map<String, String> _buildAliases() {
    final m = <String, String>{};
    for (final d in destinations) {
      for (final kw in d.keywords) {
        final key = _normalize(kw);
        assert(
          !m.containsKey(key) || m[key] == d.route,
          'Keyword collision: "$kw" (normalized "$key") maps to both '
          '${m[key]} and ${d.route}',
        );
        m[key] = d.route;
      }
      for (final variant in d.variants) {
        for (final kw in variant.keywords) {
          final key = _normalize(kw);
          assert(
            !m.containsKey(key) || m[key] == variant.route,
            'Keyword collision: "$kw" (normalized "$key") maps to both '
            '${m[key]} and ${variant.route}',
          );
          m[key] = variant.route;
        }
      }
    }
    m['onboarding'] = onboarding; // legacy compat alias (not a destination)
    return m;
  }

  static final RegExp _leadingSlash = RegExp(r'^/+');
  static final RegExp _aliasPunctuation = RegExp(r'[\s_-]');

  static String _normalize(String input) => input
      .trim()
      .toLowerCase()
      .replaceAll(_leadingSlash, '')
      .replaceAll(_aliasPunctuation, '');

  /// Resolve a typed slash command (e.g. `/widget-hub`, `/Skills`) to a
  /// registered route, or null if nothing matches. Matching ignores the
  /// leading slash, case, and any `-`/`_`/space punctuation.
  static String? resolveCommand(String input) {
    final key = _normalize(input);
    if (key.isEmpty) return null;
    return _commandAliases[key];
  }

  /// One `/<id>` per destination, for `/help`-style discovery.
  static List<String> get commandList => [
    for (final d in destinations) '/${d.id}',
  ];
}
