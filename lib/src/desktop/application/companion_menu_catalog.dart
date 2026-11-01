import 'package:maaso/src/app/routing/app_route_catalog.dart';

enum CompanionMenuGroup {
  conversation('companion.menu.group.conversation'),
  explore('companion.menu.group.explore'),
  create('companion.menu.group.create'),
  tools('companion.menu.group.tools'),
  devices('companion.menu.group.devices'),
  system('companion.menu.group.system');

  const CompanionMenuGroup(this.labelKey);

  final String labelKey;
}

/// Semantic icon names. Presentation code maps these to the active icon set.
enum CompanionMenuIcon {
  home,
  chat,
  moments,
  memory,
  settings,
  advanced,
  skills,
  store,
  dashboard,
  game,
  applets,
  qr,
  avatar,
  world,
  feed,
  creator,
  highlights,
  projector,
  unknown,
}

class CompanionMenuEntry {
  const CompanionMenuEntry({
    required this.destination,
    required this.group,
    required this.icon,
    required this.labelKey,
    required this.searchTerms,
  });

  final AppDestination destination;
  final CompanionMenuGroup group;
  final CompanionMenuIcon icon;
  final String labelKey;
  final List<String> searchTerms;
}

class CompanionMenuCatalog {
  const CompanionMenuCatalog._();

  static const List<String> _preferredIds = <String>[
    'agent_space',
    'chat',
    'skills',
    'widgets_hub',
    'moments',
    'settings',
  ];

  static const Map<String, _MenuPresentation> _presentations = {
    'accountDeletion': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.settings,
      'account_deletion.title',
    ),
    'peopleSafety': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.settings,
      'people_safety.title',
    ),
    'privacy': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.settings,
      'privacy.title',
    ),
    'profile': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.avatar,
      'profile.title',
    ),
    'membership': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.store,
      'membership.title',
    ),
    'onboarding': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.avatar,
      'identity.onboarding.title',
    ),
    'home': _MenuPresentation(
      CompanionMenuGroup.conversation,
      CompanionMenuIcon.home,
      'home.title',
    ),
    'chat': _MenuPresentation(
      CompanionMenuGroup.conversation,
      CompanionMenuIcon.chat,
      'chat.title',
    ),
    'moments': _MenuPresentation(
      CompanionMenuGroup.conversation,
      CompanionMenuIcon.moments,
      'moments.title',
    ),
    'memory_wall': _MenuPresentation(
      CompanionMenuGroup.conversation,
      CompanionMenuIcon.memory,
      'memory_wall.title',
    ),
    'memory_ledger': _MenuPresentation(
      CompanionMenuGroup.conversation,
      CompanionMenuIcon.memory,
      'memory_ledger.title',
    ),
    'settings': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.settings,
      'settings.title',
    ),
    'advanced_features': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.advanced,
      'settings.advanced.title',
    ),
    'skills': _MenuPresentation(
      CompanionMenuGroup.tools,
      CompanionMenuIcon.skills,
      'skills.title',
    ),
    'skill_store': _MenuPresentation(
      CompanionMenuGroup.tools,
      CompanionMenuIcon.store,
      'skill_store.title',
    ),
    'dashboard': _MenuPresentation(
      CompanionMenuGroup.system,
      CompanionMenuIcon.dashboard,
      'dashboard.title',
    ),
    'game_feed': _MenuPresentation(
      CompanionMenuGroup.explore,
      CompanionMenuIcon.game,
      'game_feed.title',
    ),
    'widgets_hub': _MenuPresentation(
      CompanionMenuGroup.tools,
      CompanionMenuIcon.applets,
      'widgets_hub.title',
    ),
    'my_applets': _MenuPresentation(
      CompanionMenuGroup.tools,
      CompanionMenuIcon.applets,
      'widgets.mine_title',
    ),
    'avatars': _MenuPresentation(
      CompanionMenuGroup.create,
      CompanionMenuIcon.avatar,
      'avatars.title',
    ),
    'agent_space': _MenuPresentation(
      CompanionMenuGroup.explore,
      CompanionMenuIcon.world,
      'home.menu.agent_space',
    ),
    'projector': _MenuPresentation(
      CompanionMenuGroup.devices,
      CompanionMenuIcon.projector,
      'projector.title',
    ),
  };

  static final List<CompanionMenuEntry> entries = List.unmodifiable(
    AppRouteCatalog.menuDestinations
        .where((destination) => destination.id != 'agent_media')
        .map(_entryForDestination),
  );

  static final List<CompanionMenuEntry> preferredEntries = List.unmodifiable(
    _preferredIds.map(
      (id) => entries.singleWhere((entry) => entry.destination.id == id),
    ),
  );

  static final List<String> coverageIssues = List.unmodifiable(
    _findCoverageIssues(),
  );

  static CompanionMenuEntry _entryForDestination(AppDestination destination) {
    final presentation = _presentations[destination.id];
    return CompanionMenuEntry(
      // Home owns the self-chat menu destination.
      destination: destination.id == 'chat'
          ? AppDestination(
              id: destination.id,
              route: AppRouteCatalog.home,
              title: destination.title,
              keywords: destination.keywords,
              variants: destination.variants,
            )
          : destination,
      group: presentation?.group ?? CompanionMenuGroup.system,
      icon: presentation?.icon ?? CompanionMenuIcon.unknown,
      labelKey: presentation?.labelKey ?? '',
      searchTerms: List.unmodifiable(<String>{
        destination.id,
        destination.title,
        ...destination.allKeywords,
      }),
    );
  }

  static List<String> _findCoverageIssues() {
    final issues = <String>[];
    final destinationIds = AppRouteCatalog.menuDestinations
        .map((destination) => destination.id)
        .toList(growable: false);
    final uniqueDestinationIds = destinationIds.toSet();

    for (final id in uniqueDestinationIds) {
      if (!_presentations.containsKey(id)) {
        issues.add('Missing menu presentation for destination "$id".');
      }
    }
    for (final id in _presentations.keys) {
      if (!uniqueDestinationIds.contains(id)) {
        issues.add('Menu presentation "$id" has no public destination.');
      }
    }
    if (destinationIds.length != uniqueDestinationIds.length) {
      issues.add('Public destination ids must be unique.');
    }
    return issues;
  }
}

class _MenuPresentation {
  const _MenuPresentation(this.group, this.icon, this.labelKey);

  final CompanionMenuGroup group;
  final CompanionMenuIcon icon;
  final String labelKey;
}
