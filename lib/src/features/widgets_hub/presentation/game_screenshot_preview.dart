import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:sembast/sembast.dart';

/// A static cover, including on the first visible feed frame. Reading a cover
/// never creates a player, fetches game content, or executes game JavaScript.
class GameScreenshotPreview extends StatefulWidget {
  const GameScreenshotPreview({
    required this.identity,
    required this.revision,
    required this.title,
    this.shareUrl,
    this.localItem,
    this.active = true,
    super.key,
  }) : assert((shareUrl == null) != (localItem == null));

  final String identity;
  final String revision;
  final String title;
  final Uri? shareUrl;
  final AgentWidget? localItem;
  final bool active;

  static const maxImageBytes = 256 * 1024;
  static const maxImageDimension = 640;

  /// Clears decoded memory only. Real covers survive app restarts in Sembast.
  @visibleForTesting
  static void clearCache() => GameScreenshotStore._memory.clear();

  @override
  State<GameScreenshotPreview> createState() => _GameScreenshotPreviewState();
}

/// Admission binds pixels to the current account, origin and exact game
/// revision. Local rows are re-read without preparing or executing a Surface.
@immutable
class GameScreenshotSource {
  const GameScreenshotSource._({
    required this.cacheKey,
    required this.scope,
    required DBService owner,
    required Database database,
    required String fingerprint,
    required String origin,
    this.shareUrl,
    this.localItem,
  }) : _owner = owner,
       _database = database,
       _fingerprint = fingerprint,
       _origin = origin;

  final String cacheKey;
  final String scope;
  final AgentWidget? localItem;
  final Uri? shareUrl;
  final DBService _owner;
  final Database _database;
  final String _fingerprint;
  final String _origin;
  static final _widgets = intMapStoreFactory.store('agent_widgets');

  static Future<GameScreenshotSource?> resolve({
    required String identity,
    required String revision,
    Uri? shareUrl,
    AgentWidget? localItem,
  }) async {
    if (!SurfaceRuntime.presentationCapabilityAvailable ||
        identity.isEmpty ||
        revision.isEmpty ||
        (shareUrl == null) == (localItem == null)) {
      return null;
    }
    final owner = appServices.maybeFind<DBService>();
    if (owner == null) return null;
    try {
      final database = owner.raw;
      final scope = AppletLocalOwnership.currentScopeKey();
      final origin = appServices.maybeFind<AppEnvironmentService>()?.baseUri;
      final String fingerprint;
      if (shareUrl != null) {
        if (origin == null ||
            !isTrustedAppletShareUrl(shareUrl, trustedOrigin: origin)) {
          return null;
        }
        // Public, cloud inventory and search rows share the same pixels.
        fingerprint = jsonEncode(['public', shareUrl.toString(), revision]);
      } else {
        final item = localItem!;
        if (item.id == null ||
            !isAppletPresentationDiscoverable(item, scopeKey: scope)) {
          return null;
        }
        final project = surfaceProjectFromWidget(item);
        if (project.experienceType != SurfaceExperienceType.game) return null;
        SurfaceProjectValidator.validateForPublicGame(project);
        // createdAt remains unchanged after editing, so it is not a revision.
        fingerprint = jsonEncode(project.toJson());
      }
      final source = GameScreenshotSource._(
        cacheKey: sha256
            .convert(
              utf8.encode(
                jsonEncode([scope, origin?.origin ?? '', fingerprint]),
              ),
            )
            .toString(),
        scope: scope,
        owner: owner,
        database: database,
        fingerprint: fingerprint,
        origin: origin?.origin ?? '',
        shareUrl: shareUrl,
        localItem: localItem,
      );
      return await source._revalidate() ? source : null;
    } catch (_) {
      return null;
    }
  }

  bool get isCurrent {
    if (scope != AppletLocalOwnership.currentScopeKey() ||
        _origin !=
            (appServices.maybeFind<AppEnvironmentService>()?.baseUri.origin ??
                '') ||
        !SurfaceRuntime.presentationCapabilityAvailable ||
        !identical(appServices.maybeFind<DBService>(), _owner)) {
      return false;
    }
    try {
      return identical(_owner.raw, _database);
    } on StateError {
      return false;
    }
  }

  Future<bool> _revalidate({DatabaseClient? client}) async {
    if (!isCurrent) return false;
    final item = localItem;
    if (item == null) return true;
    final raw = await _widgets.record(item.id!).get(client ?? _database);
    if (!isCurrent || raw == null) return false;
    final current = AgentWidget.fromJson(raw, id: item.id);
    if (!isAppletPresentationDiscoverable(current, scopeKey: scope)) {
      return false;
    }
    return jsonEncode(surfaceProjectFromWidget(current).toJson()) ==
        _fingerprint;
  }

  /// PNG/JPEG only, validated by the image codec after checking encoded bounds.
  /// Descriptor dimensions are checked before allocating decoded image pixels.
  static Future<Uint8List?> validateImage(Uint8List? bytes) async {
    if (bytes == null ||
        bytes.length < 24 ||
        bytes.length > GameScreenshotPreview.maxImageBytes) {
      return null;
    }
    final png = listEquals(bytes.sublist(0, 8), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);
    final jpeg = bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
    if (!png && !jpeg) return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > GameScreenshotPreview.maxImageDimension ||
          descriptor.height > GameScreenshotPreview.maxImageDimension) {
        return null;
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      if (image.width != descriptor.width ||
          image.height != descriptor.height) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// Bounded account-owned cover persistence. Its write entry point accepts a
/// snapshot of an already open player; it cannot construct or launch one.
abstract final class GameScreenshotStore {
  static const maxEntries = 16;
  static final _records = stringMapStoreFactory.store('game_covers.v1');
  static final _memory = <String, Uint8List>{};
  static final _changes = ValueNotifier<int>(0);

  @visibleForTesting
  static http.Client Function()? debugClientFactory;

  static Future<Uint8List?> load(GameScreenshotSource source) async {
    try {
      if (!await source._revalidate()) return null;
      if (source.shareUrl != null) return await _loadPublishedCover(source);
      final cached = _memory.remove(source.cacheKey);
      if (cached != null) {
        _memory[source.cacheKey] = cached;
        return cached;
      }
      final record = await _records
          .record(source.cacheKey)
          .get(source._database);
      final encoded = record?['image'];
      if (record?['schemaVersion'] != 1 ||
          encoded is! String ||
          encoded.length > GameScreenshotPreview.maxImageBytes * 4 ~/ 3 + 4) {
        return null;
      }
      final pixels = await GameScreenshotSource.validateImage(
        base64Decode(encoded),
      );
      if (pixels == null || !await source._revalidate()) return null;
      _remember(source.cacheKey, pixels);
      return pixels;
    } catch (_) {
      return null;
    }
  }

  /// Re-check current publication for every public cover load. A withdrawn or
  /// unavailable cover must never be resurrected from the device's old cache.
  static Future<Uint8List?> _loadPublishedCover(
    GameScreenshotSource source,
  ) async {
    final shareUrl = source.shareUrl!;
    final uri = shareUrl.replace(
      pathSegments: [...shareUrl.pathSegments, 'cover'],
    );
    final client = debugClientFactory?.call() ?? http.Client();
    try {
      final pixels = await (() async {
        final response = await client.send(
          http.Request('GET', uri)
            ..followRedirects = false
            ..headers['Accept'] = 'image/jpeg, image/png',
        );
        if (!source.isCurrent || response.statusCode != 200) return null;
        final mime = response.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if ((mime != 'image/jpeg' && mime != 'image/png') ||
            (response.contentLength ?? 0) >
                GameScreenshotPreview.maxImageBytes) {
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (!source.isCurrent ||
              bytes.length + chunk.length >
                  GameScreenshotPreview.maxImageBytes) {
            return null;
          }
          bytes.add(chunk);
        }
        final image = bytes.takeBytes();
        if (image.length < 24 ||
            (mime == 'image/png' &&
                !listEquals(image.sublist(0, 8), [
                  137,
                  80,
                  78,
                  71,
                  13,
                  10,
                  26,
                  10,
                ])) ||
            (mime == 'image/jpeg' &&
                !(image[0] == 255 && image[1] == 216 && image[2] == 255))) {
          return null;
        }
        return GameScreenshotSource.validateImage(image);
      })().timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (!source.isCurrent) return null;
      if (pixels == null) {
        _memory.remove(source.cacheKey);
        await _records.record(source.cacheKey).delete(source._database);
        return null;
      }
      await _save(source, pixels, isCurrent: () => source.isCurrent);
      return source.isCurrent ? pixels : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Called only after an intentional open and a visible player's first frame.
  /// The caller owns WebView lifecycle and supplies its mounted/session guard.
  static Future<bool> captureOpenedPlayer({
    required String identity,
    required String revision,
    Uri? shareUrl,
    AgentWidget? localItem,
    required Future<Uint8List?> Function() capture,
    required bool Function() isCurrent,
  }) async {
    bool canCapture() {
      final phase = WidgetsBinding.instance.lifecycleState;
      return isCurrent() &&
          (phase == null || phase == AppLifecycleState.resumed);
    }

    try {
      if (!canCapture()) return false;
      final source = await GameScreenshotSource.resolve(
        identity: identity,
        revision: revision,
        shareUrl: shareUrl,
        localItem: localItem,
      );
      if (source == null || !canCapture()) return false;
      if (await load(source) != null) return true;
      if (!canCapture() || !source.isCurrent) return false;
      final pixels = await capture()
          .then<Uint8List?>((value) => value)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      if (!canCapture()) return false;
      final image = await GameScreenshotSource.validateImage(pixels);
      if (image == null || !canCapture() || !await source._revalidate()) {
        return false;
      }
      await _save(source, image, isCurrent: canCapture);
      if (!canCapture() || !source.isCurrent) return false;
      _changes.value++;
      return true;
    } catch (_) {
      // Covers are optional; a failed snapshot must never interrupt gameplay.
      return false;
    }
  }

  static Future<void> _save(
    GameScreenshotSource source,
    Uint8List image, {
    required bool Function() isCurrent,
  }) async {
    await source._database.transaction((transaction) async {
      if (!isCurrent() || !await source._revalidate(client: transaction)) {
        throw StateError('game_cover_source_changed');
      }
      await _records.record(source.cacheKey).put(transaction, {
        'schemaVersion': 1,
        'image': base64Encode(image),
        'savedAt': DateTime.now().microsecondsSinceEpoch,
      });
      final records = await _records.find(
        transaction,
        finder: Finder(sortOrders: [SortOrder('savedAt')]),
      );
      for (final record in records.take(
        (records.length - maxEntries).clamp(0, records.length),
      )) {
        await _records.record(record.key).delete(transaction);
        _memory.remove(record.key);
      }
      if (!isCurrent() || !source.isCurrent) {
        throw StateError('game_cover_source_changed');
      }
    });
    if (!isCurrent() || !source.isCurrent) return;
    _remember(source.cacheKey, image);
  }

  static void _remember(String key, Uint8List pixels) {
    _memory.remove(key);
    _memory[key] = pixels;
    while (_memory.length > maxEntries) {
      _memory.remove(_memory.keys.first);
    }
  }
}

class _GameScreenshotPreviewState extends State<GameScreenshotPreview>
    with WidgetsBindingObserver {
  final _scopeWorkers = <Worker>[];
  AppCapabilitySnapshotService? _capabilities;
  Uint8List? _pixels;
  String? _signature;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scopeWorkers.addAll(AppletLocalOwnership.watchScope(_reload));
    _capabilities = appServices.maybeFind<AppCapabilitySnapshotService>();
    _capabilities?.addListener(_reload);
    GameScreenshotStore._changes.addListener(_reload);
    _reload();
  }

  String _requestSignature() {
    final identity = [
      AppletLocalOwnership.currentScopeKey(),
      widget.identity,
      widget.revision,
      widget.shareUrl?.toString(),
      widget.active,
    ];
    try {
      return jsonEncode([...identity, widget.localItem?.toJson()]);
    } catch (_) {
      return jsonEncode([...identity, 'invalid-project']);
    }
  }

  @override
  void didUpdateWidget(GameScreenshotPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_signature != _requestSignature()) _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
    } else {
      _generation++;
    }
  }

  void _reload() {
    final generation = ++_generation;
    _signature = _requestSignature();
    _pixels = null;
    if (mounted) setState(() {});
    if (!widget.active) return;
    unawaited(_load(generation));
  }

  Future<void> _load(int generation) async {
    final source = await GameScreenshotSource.resolve(
      identity: widget.identity,
      revision: widget.revision,
      shareUrl: widget.shareUrl,
      localItem: widget.localItem,
    );
    final pixels = source == null
        ? null
        : await GameScreenshotStore.load(source);
    if (!mounted || generation != _generation || !widget.active) return;
    setState(() => _pixels = pixels);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _capabilities?.removeListener(_reload);
    GameScreenshotStore._changes.removeListener(_reload);
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: _pixels != null,
      label: widget.title,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: MaasoFrostTokens.darkCanvas),
            if (_pixels case final bytes?)
              Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: false)
            else
              DecoratedBox(
                key: const ValueKey('game-static-cover-placeholder'),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      MaasoFrostTokens.darkMuted,
                      MaasoFrostTokens.darkCanvas,
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
