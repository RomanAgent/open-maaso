import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';

/// Bounded media bytes, verified before any decoder sees them. No credentials
/// or redirects are sent to media origins.
Future<Uint8List> fetchStorePreview(
  StoreAsset item, {
  http.Client? client,
}) async {
  if (item.preview['state'] != 'available') {
    throw const FormatException('preview_unavailable');
  }
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final request = http.Request(
      'GET',
      Uri.parse(item.preview['url'] as String),
    )..followRedirects = false;
    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 15));
    const limit = 16 * 1024 * 1024;
    if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
      throw const FormatException('preview_unavailable');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('preview_too_large');
      }
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (sha256.convert(result).toString() != item.preview['sha256']) {
      throw const FormatException('preview_checksum_mismatch');
    }
    return result;
  } finally {
    if (owned) httpClient.close();
  }
}

class StoreAssetPreview extends StatefulWidget {
  const StoreAssetPreview({
    super.key,
    required this.item,
    required this.service,
    required this.canContinue,
    this.previewClientFactory,
    this.whenInvalidated,
  });
  final StoreAsset item;
  final AssetStoreService service;
  final bool Function() canContinue;

  /// Each load owns and closes its fresh media client, including cancellation.
  final http.Client Function()? previewClientFactory;
  final Future<void>? whenInvalidated;
  @override
  State<StoreAssetPreview> createState() => _StoreAssetPreviewState();
}

class _StoreAssetPreviewState extends State<StoreAssetPreview>
    with WidgetsBindingObserver {
  Uint8List? _bytes;
  VideoPlayerController? _video;
  Directory? _directory;
  http.Client? _network;
  final _viewport = GlobalKey();
  bool _failed = false;
  bool _recorded = false;
  bool _loaded = false;
  bool _started = false;
  bool _progressed = false;
  bool _reducedMotion = false;
  bool _suspended = false;
  bool _closed = false;
  int _generation = 0;
  late final _scope = widget.service.scopeKey;
  bool get _current =>
      mounted &&
      !_closed &&
      widget.canContinue() &&
      widget.service.scopeKey == _scope;
  bool _owns(int generation) => _current && generation == _generation;
  bool get _visible {
    if (!_current ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final box = _viewport.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    var visible = (box.localToGlobal(Offset.zero) & box.size).intersect(
      Offset.zero & MediaQuery.sizeOf(context),
    );
    RenderObject child = box;
    for (
      var parent = child.parent;
      parent is RenderObject;
      parent = child.parent
    ) {
      if (parent is RenderOffstage && parent.offstage ||
          parent is RenderOpacity && parent.opacity <= 0) {
        return false;
      }
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), clip),
        );
      }
      if (visible.isEmpty) return false;
      child = parent;
    }
    return !visible.isEmpty;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final invalidated =
        widget.whenInvalidated ??
        appServices
            .maybeFind<AccountStorageScopeService>()
            ?.activeMount
            ?.whenInvalidated;
    invalidated?.then((_) {
      if (mounted) {
        _closed = true;
        _retire();
        setState(() => _failed = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (!_loaded) {
      _loaded = true;
      unawaited(_load());
    } else if (_reducedMotion) {
      unawaited(_video?.pause());
    }
  }

  @override
  void didUpdateWidget(covariant StoreAssetPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_current ||
        oldWidget.item.key != widget.item.key ||
        oldWidget.item.preview.toString() != widget.item.preview.toString() ||
        !identical(oldWidget.service, widget.service)) {
      _closed = true;
      _retire();
      _failed = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted && !_closed) {
      _retire();
      setState(() => _suspended = true);
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _started = false;
    _progressed = false;
    _suspended = false;
    try {
      final client = widget.previewClientFactory?.call() ?? http.Client();
      _network = client;
      final bytes = await fetchStorePreview(widget.item, client: client);
      client.close();
      if (identical(_network, client)) _network = null;
      if (!_owns(generation)) return;
      if (widget.item.preview['kind'] == 'gif') {
        setState(() => _bytes = bytes);
        return;
      }
      final temp = await getTemporaryDirectory();
      if (!_owns(generation)) return;
      await temp.create(recursive: true);
      if (!_owns(generation)) return;
      final directory = await temp.createTemp('asset-preview-');
      if (!_owns(generation)) {
        await directory.delete(recursive: true);
        return;
      }
      _directory = directory;
      final file = await File(
        '${directory.path}/preview.mp4',
      ).writeAsBytes(bytes);
      if (!_owns(generation)) return;
      final video = VideoPlayerController.file(file);
      _video = video;
      await video.initialize();
      if (!_owns(generation)) return;
      await video.setVolume(0);
      await video.setLooping(false);
      if (!_owns(generation)) return;
      video.addListener(_videoFrame);
      setState(() {});
    } catch (_) {
      if (_owns(generation)) {
        _retire();
        setState(() => _failed = true);
      }
    }
  }

  void _videoFrame() {
    if (!_current) {
      _closed = true;
      _retire();
      if (mounted) setState(() => _failed = true);
      return;
    }
    final video = _video;
    if (video == null) return;
    if (video.value.hasError) {
      _retire();
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!_visible && video.value.isPlaying) {
      unawaited(video.pause());
      return;
    }
    if (video.value.position > Duration.zero && !_progressed) {
      _progressed = true;
      setState(() {});
    }
  }

  void _visibleFrame(int generation) {
    if (!_owns(generation) || !_visible) return;
    if (_progressed) _record();
    if (!_started && !_reducedMotion && _video != null) unawaited(_play());
  }

  Future<void> _play() async {
    final video = _video;
    if (!_visible || video == null || !video.value.isInitialized) return;
    _started = true;
    await video.play();
    if (!_current) {
      _retire();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _record() {
    if (!_current || !_visible || _recorded) return;
    _recorded = true;
    unawaited(
      widget.service
          .recordPreview(widget.item, const Uuid().v4())
          .catchError((Object _) {}),
    );
  }

  void _retire() {
    ++_generation;
    _network?.close();
    _network = null;
    final video = _video;
    final directory = _directory;
    _video = null;
    _directory = null;
    _bytes = null;
    video?.removeListener(_videoFrame);
    unawaited(() async {
      try {
        await video?.pause();
      } catch (_) {}
      try {
        await video?.dispose();
      } catch (_) {}
      try {
        if (directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return Text('asset_store.preview_failed'.tr);
    if (_suspended) {
      return TextButton.icon(
        onPressed: _current
            ? () {
                setState(() => _suspended = false);
                unawaited(_load());
              }
            : null,
        icon: const Icon(Icons.play_arrow),
        label: Text('asset_store.preview'.tr),
      );
    }
    if (_bytes case final bytes?) {
      return SizedBox(
        key: _viewport,
        height: 220,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame != null) {
              final generation = _generation;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_owns(generation)) _record();
              });
            }
            return child;
          },
          errorBuilder: (_, _, _) => Text('asset_store.preview_failed'.tr),
        ),
      );
    }
    final video = _video;
    if (video == null || !video.value.isInitialized) {
      return const SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _visibleFrame(generation),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: _viewport,
          height: 220,
          child: AspectRatio(
            aspectRatio: video.value.aspectRatio,
            child: VideoPlayer(video),
          ),
        ),
        IconButton(
          key: const ValueKey('asset-preview-play-pause'),
          tooltip:
              (video.value.isPlaying
                      ? 'asset_store.pause_preview'
                      : 'asset_store.preview')
                  .tr,
          onPressed: !_current
              ? null
              : () async {
                  if (video.value.isPlaying) {
                    await video.pause();
                    if (_current) setState(() {});
                  } else {
                    await _play();
                  }
                },
          icon: Icon(video.value.isPlaying ? Icons.pause : Icons.play_arrow),
        ),
      ],
    );
  }
}
