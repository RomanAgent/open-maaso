import 'dart:convert';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';

/// Lets the agent open any app page on request ("open settings",
/// "where's my memory wall", "去朋友圈"). Resolves the page through the
/// [CapabilityRegistry]'s navigate capabilities, so cloud + on-device share one
/// destination catalog. Navigation is reversible (low risk) → no confirmation.
class AppNavigateSkill extends AgentSkill {
  AppNavigateSkill({
    CapabilityRegistry? registry,
    this.agentId = 'self',
    AppPlatformCapabilities? platformCapabilities,
    AppCapabilitySnapshotService? capabilitySnapshots,
  }) : _injected = registry,
       _injectedCapabilitySnapshots = capabilitySnapshots,
       _platformCapabilities =
           platformCapabilities ?? AppPlatformCapabilities.current();

  /// Owning agent. Core skills are force-registered into every runtime —
  /// including a2a peer agents — and navigation is a global side effect on the
  /// owner's screen, so [_openPage] only acts for the self agent (mirrors the
  /// self-only avatar gating in AgentRuntime).
  final String agentId;

  final CapabilityRegistry? _injected;
  final AppCapabilitySnapshotService? _injectedCapabilitySnapshots;
  final AppPlatformCapabilities _platformCapabilities;
  AppCapabilitySnapshotService? _leaseOwner;
  AppCapabilitySnapshotLease? _capabilityLease;
  CapabilityRegistry get _registry =>
      _injected ?? appServices.find<CapabilityRegistry>();
  AppCapabilitySnapshotLease? get _lease {
    final owner =
        _injectedCapabilitySnapshots ??
        appServices.maybeFind<AppCapabilitySnapshotService>();
    if (owner == null) return null;
    if (!identical(_leaseOwner, owner)) {
      _leaseOwner = owner;
      _capabilityLease = null;
    }
    final existing = _capabilityLease;
    if (existing != null && owner.isCurrent(existing)) return existing;
    _leaseOwner = owner;
    try {
      return _capabilityLease = owner.acquireLease(<AppCapabilityKey>[
        AppCapabilityKey.skill('app_navigate'),
      ], requireVisible: true).lease;
    } catch (_) {
      return null;
    }
  }

  List<AppDestination> get _destinations {
    final lease = _lease;
    if (_leaseOwner != null && lease == null) {
      return const <AppDestination>[];
    }
    return availableNavigationDestinations(
      snapshot: lease?.snapshot,
      platformCapabilities: _platformCapabilities,
    );
  }

  @override
  String get skillName => 'AppNavigate';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Open / jump to a page in this app for the owner. Use whenever they ask '
      'to go somewhere, where something is, or to see/manage a feature — '
      'e.g. "open settings", "where is my memory wall", "去朋友圈看看".';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'openPage': _openPage,
    'listPages': _listPages,
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    'openPage': {
      'type': 'object',
      'properties': {
        'page': {
          'type': 'string',
          'enum': _destinations.map((d) => d.id).toList(),
          'description': 'Which app page to open.',
        },
        if (_destinations.any((destination) => destination.variants.isNotEmpty))
          'channel': {
            'type': 'string',
            'enum': [
              for (final destination in _destinations)
                for (final variant in destination.variants) variant.id,
            ],
            'description':
                'Optional section declared by the selected destination.',
          },
      },
      'required': ['page'],
    },
    'listPages': {'type': 'object', 'properties': {}},
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'openPage':
        'Navigate the app to the given page by id. Returns {"status":"ok","page":..} or {"error":..}.',
    'listPages':
        'List all navigable page ids and their titles. Returns {"pages":[{"id":..,"title":..}]}.',
  };

  dynamic _openPage(List<dynamic> args) {
    if (agentId != 'self') {
      return jsonEncode({
        'error': 'owner_only',
        'message': AgentPromptCatalog.text('navigation.error.owner_only'),
      });
    }
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      final lease = _lease;
      final destinations = _leaseOwner != null && lease == null
          ? const <AppDestination>[]
          : availableNavigationDestinations(
              snapshot: lease?.snapshot,
              platformCapabilities: _platformCapabilities,
            );
      final raw = args[0];
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) {
        return '{"error":"expected_object"}';
      }
      final page = decoded['page']?.toString().trim() ?? '';
      final channel = decoded['channel']?.toString().trim().toLowerCase();
      final destination = destinations
          .where((item) => item.id == page)
          .firstOrNull;
      if (destination == null) {
        final declaredDestination = AppRouteCatalog.destinations
            .where((item) => item.id == page)
            .firstOrNull;
        final decision = declaredDestination == null
            ? null
            : lease?.snapshot.decision(
                AppCapabilityKey.route(declaredDestination.id),
              );
        return jsonEncode({
          'error': 'unavailable_page',
          'page': page,
          if (decision != null && decision.reasonCodes.isNotEmpty)
            'reasons': decision.reasonCodes.toList(growable: false),
          'valid': destinations.map((d) => d.id).toList(),
        });
      }
      if (lease != null) {
        final owner = _leaseOwner;
        if (owner == null || !owner.isCurrent(lease)) {
          return jsonEncode({'error': 'capability_stale', 'page': page});
        }
        final decision = lease.snapshot.decision(
          AppCapabilityKey.route(destination.id),
        );
        if (decision?.isUsable != true) {
          return jsonEncode({
            'error': 'unavailable_page',
            'page': page,
            'reasons':
                decision?.reasonCodes.toList(growable: false) ??
                const <String>['capability_not_declared'],
            'valid': destinations.map((d) => d.id).toList(),
          });
        }
      }
      final cap = _registry.byId('nav.$page');
      if (cap == null) {
        return jsonEncode({
          'error': 'unknown_page',
          'page': page,
          'valid': destinations.map((d) => d.id).toList(),
        });
      }
      if (channel != null &&
          channel.isNotEmpty &&
          destination.variant(channel) == null) {
        return jsonEncode({
          'error': 'invalid_channel',
          'channel': channel,
          'valid': destination.variants.map((item) => item.id).toList(),
        });
      }
      final result = cap.run({'channel': channel});
      return jsonEncode({
        'status': result.ok ? 'ok' : 'error',
        'page': page,
        if (channel != null && channel.isNotEmpty) 'channel': channel,
        'message': result.message,
      });
    } catch (_) {
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  dynamic _listPages(List<dynamic> _) {
    final destinations = _destinations;
    return jsonEncode({
      'pages': [
        for (final d in destinations)
          {'id': d.id, 'title': navigationDestinationTitle(d.id)},
      ],
    });
  }
}
