import 'dart:convert';
import 'dart:math';

import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';

/// A narrow, typed route contract for Agent-requested applet navigation.
///
/// Games use their dedicated feed route. Only one known category and an
/// optional opaque catalog id are accepted. Display
/// metadata and URLs never become navigation authority.
final class AppletHubRouteIntent {
  factory AppletHubRouteIntent({
    required AppletCategory category,
    String? openId,
  }) {
    final normalizedOpenId = openId?.trim();
    if (normalizedOpenId != null &&
        (normalizedOpenId != openId ||
            !_opaqueAppletIdPattern.hasMatch(normalizedOpenId) ||
            _urlLikeIdPattern.hasMatch(normalizedOpenId))) {
      throw const FormatException('invalid_applet_open_id');
    }
    return AppletHubRouteIntent._(category: category, openId: normalizedOpenId);
  }

  const AppletHubRouteIntent._({required this.category, this.openId});

  final AppletCategory category;
  final String? openId;

  String get location {
    final isGameFeed = category == AppletCategory.game;
    return Uri(
      path: isGameFeed ? AppRouteCatalog.gameFeed : AppRouteCatalog.widgetsHub,
      queryParameters: isGameFeed && openId == null
          ? null
          : <String, String>{
              if (!isGameFeed) 'category': category.name,
              'open': ?openId,
            },
    ).toString();
  }

  bool matchesLocation(String rawLocation) {
    final parsed = tryParse(rawLocation);
    return parsed != null &&
        parsed.category == category &&
        parsed.openId == openId;
  }

  static AppletHubRouteIntent parse(String rawLocation) {
    if (rawLocation.isEmpty || rawLocation.runes.length > 256) {
      throw const FormatException('invalid_applet_hub_location');
    }
    final uri = Uri.tryParse(rawLocation);
    final isGameFeed = uri?.path == AppRouteCatalog.gameFeed;
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (!isGameFeed && uri.path != AppRouteCatalog.widgetsHub)) {
      throw const FormatException('invalid_applet_hub_location');
    }
    final allowedKeys = isGameFeed
        ? const <String>{'open'}
        : const <String>{'category', 'open'};
    if (uri.queryParametersAll.keys.any((key) => !allowedKeys.contains(key)) ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const FormatException('invalid_applet_hub_query');
    }
    final category = isGameFeed
        ? AppletCategory.game
        : switch (uri.queryParameters['category'] ?? 'all') {
            'all' => AppletCategory.all,
            'game' => AppletCategory.game,
            'travel' => AppletCategory.travel,
            'tools' => AppletCategory.tools,
            _ => throw const FormatException('invalid_applet_hub_category'),
          };
    return AppletHubRouteIntent(
      category: category,
      openId: uri.queryParameters['open'],
    );
  }

  static AppletHubRouteIntent? tryParse(String rawLocation) {
    try {
      return parse(rawLocation);
    } on FormatException {
      return null;
    }
  }
}

/// Opaque handle for one pending, process-local Hub open authorization.
final class AppletHubOpenTicket {
  const AppletHubOpenTicket._(this.intent, this._authority);

  final AppletHubRouteIntent intent;
  final Object _authority;
}

/// Atomically hands one exact catalog result from a Skill to the Hub page.
///
/// The route token is only a lookup handle. Authority stays process-local and
/// binds the owner, account/environment/locale context, expiry, immutable page
/// identity and exact item identity. Restored or manually constructed routes
/// therefore grant nothing.
final class AppletHubOpenBroker {
  AppletHubOpenBroker({
    DateTime Function()? now,
    String Function()? tokenFactory,
  }) : _now = now ?? DateTime.now,
       _tokenFactory = tokenFactory ?? _secureRouteToken;

  final DateTime Function() _now;
  final String Function() _tokenFactory;
  _PendingAppletHubOpen? _pending;

  AppletHubOpenTicket issue({
    required String ownerAgentId,
    required AppletCategory category,
    required String requestContextKey,
    required DateTime expiresAt,
    required AppletCatalogPage page,
    required AppletCatalogItem item,
  }) {
    final owner = ownerAgentId.trim();
    final context = requestContextKey.trim();
    final deadline = expiresAt.toUtc();
    if (owner != 'self' ||
        context.isEmpty ||
        !AppletCategoryTaxonomy.matches(
          selected: category,
          item: AppletCategoryTaxonomy.forCatalogItem(item),
        ) ||
        !page.items.any((candidate) => identical(candidate, item)) ||
        !(_now().toUtc()).isBefore(deadline)) {
      throw StateError('invalid_applet_hub_open_authority');
    }
    final authority = Object();
    final intent = AppletHubRouteIntent(
      category: category,
      openId: _tokenFactory(),
    );
    _pending = _PendingAppletHubOpen(
      authority: authority,
      ownerAgentId: owner,
      intent: intent,
      requestContextKey: context,
      expiresAt: deadline,
      page: page,
      item: item,
    );
    return AppletHubOpenTicket._(intent, authority);
  }

  /// Revokes only the exact ticket, so an older navigation cannot cancel a
  /// newer grant for the same catalog item.
  void revoke(AppletHubOpenTicket ticket) {
    if (identical(_pending?.authority, ticket._authority)) _pending = null;
  }

  void revokeOwner(String ownerAgentId) {
    if (_pending?.ownerAgentId == ownerAgentId.trim()) _pending = null;
  }

  void revokeIntent({
    required String ownerAgentId,
    required AppletHubRouteIntent intent,
  }) {
    final pending = _pending;
    if (pending != null &&
        pending.ownerAgentId == ownerAgentId.trim() &&
        pending.intent.matchesLocation(intent.location)) {
      _pending = null;
    }
  }

  /// Claims and consumes the pending authority before validating it.
  /// Failed, expired, stale and mismatched attempts are therefore one-shot.
  AppletCatalogItem? claim({
    required String ownerAgentId,
    required AppletHubRouteIntent intent,
    required String currentLocation,
    required String requestContextKey,
    required String latestContextKey,
    required AppletCatalogPage? latestPage,
  }) {
    final pending = _pending;
    _pending = null;
    if (pending == null ||
        pending.ownerAgentId != ownerAgentId.trim() ||
        !pending.intent.matchesLocation(intent.location) ||
        !intent.matchesLocation(currentLocation) ||
        !(_now().toUtc()).isBefore(pending.expiresAt) ||
        requestContextKey != pending.requestContextKey ||
        latestContextKey != pending.requestContextKey ||
        !identical(latestPage, pending.page) ||
        !pending.page.items.any(
          (candidate) => identical(candidate, pending.item),
        )) {
      return null;
    }
    return pending.item;
  }
}

final AppletHubOpenBroker appletHubOpenBroker = AppletHubOpenBroker();

final class _PendingAppletHubOpen {
  const _PendingAppletHubOpen({
    required this.authority,
    required this.ownerAgentId,
    required this.intent,
    required this.requestContextKey,
    required this.expiresAt,
    required this.page,
    required this.item,
  });

  final Object authority;
  final String ownerAgentId;
  final AppletHubRouteIntent intent;
  final String requestContextKey;
  final DateTime expiresAt;
  final AppletCatalogPage page;
  final AppletCatalogItem item;
}

String _secureRouteToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

final RegExp _opaqueAppletIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,39}$',
);
final RegExp _urlLikeIdPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9+.-]*:',
  caseSensitive: false,
);
