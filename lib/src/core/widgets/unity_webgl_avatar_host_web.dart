import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;

@JS('maasoUnityAvatarHost')
external _MaasoUnityAvatarHost? get _maasoUnityAvatarHost;

@JS()
extension type _MaasoUnityAvatarHost._(JSObject _) implements JSObject {
  external JSNumber subscribe(JSFunction callback);

  external void unsubscribe(JSNumber subscriptionId);

  external void mount(web.HTMLElement container, JSString leaseId);

  external void detach(JSString leaseId);

  external void retry(JSString leaseId);
}

enum _WebGLAvatarPhase { loading, ready, error }

class UnityWebGLAvatarHost extends StatefulWidget {
  const UnityWebGLAvatarHost({
    super.key,
    required this.fallback,
    required this.viewportActive,
    this.onReady,
  });

  final Widget fallback;
  final bool viewportActive;
  final VoidCallback? onReady;

  @override
  State<UnityWebGLAvatarHost> createState() => _UnityWebGLAvatarHostState();
}

class _UnityWebGLAvatarHostState extends State<UnityWebGLAvatarHost> {
  static int _nextLease = 0;

  late final String _leaseId = 'flutter-web-avatar-${_nextLease++}';
  _MaasoUnityAvatarHost? _host;
  web.HTMLElement? _container;
  JSFunction? _eventCallback;
  JSNumber? _subscriptionId;
  _WebGLAvatarPhase _phase = _WebGLAvatarPhase.loading;
  int _generation = -1;
  int _sequence = -1;
  int _readyCallbackGeneration = -1;
  double? _progress;
  String _message = '正在加载 3D 伙伴';

  @override
  void initState() {
    super.initState();
    _connectHost();
  }

  @override
  void didUpdateWidget(covariant UnityWebGLAvatarHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewportActive == widget.viewportActive) return;
    if (widget.viewportActive) {
      _mountIfReady();
    } else {
      _host?.detach(_leaseId.toJS);
    }
  }

  @override
  void dispose() {
    _host?.detach(_leaseId.toJS);
    final subscriptionId = _subscriptionId;
    if (subscriptionId != null) _host?.unsubscribe(subscriptionId);
    _subscriptionId = null;
    _eventCallback = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _phase == _WebGLAvatarPhase.ready;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: ready ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: widget.fallback,
          ),
        ),
        HtmlElementView.fromTagName(
          key: ValueKey<String>(_leaseId),
          tagName: 'div',
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          onElementCreated: _handleElementCreated,
        ),
        if (!ready)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              minimum: const EdgeInsets.all(16),
              child: _StatusPanel(
                phase: _phase,
                progress: _progress,
                message: _message,
                onRetry: _retry,
              ),
            ),
          ),
      ],
    );
  }

  void _connectHost() {
    final host = _maasoUnityAvatarHost;
    if (host == null) {
      _phase = _WebGLAvatarPhase.error;
      _message = '3D 伙伴宿主未加载';
      return;
    }
    _host = host;
    _eventCallback = ((JSString rawEvent) {
      _handleHostEvent(rawEvent.toDart);
    }).toJS;
    _subscriptionId = host.subscribe(_eventCallback!);
    _mountIfReady();
  }

  void _handleElementCreated(Object element) {
    final container = element as web.HTMLElement;
    container
      ..className = 'maaso-unity-avatar-container'
      ..setAttribute('aria-hidden', 'true');
    container.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..overflow = 'hidden'
      ..pointerEvents = 'none'
      ..background = 'transparent';
    _container = container;
    _mountIfReady();
  }

  void _mountIfReady() {
    if (!widget.viewportActive) return;
    final host = _host;
    final container = _container;
    if (host == null || container == null) return;
    host.mount(container, _leaseId.toJS);
  }

  void _handleHostEvent(String rawEvent) {
    if (!mounted || rawEvent.length > 65536) return;
    try {
      final decoded = jsonDecode(rawEvent);
      if (decoded is! Map) return;
      final event = Map<String, dynamic>.from(decoded);
      if (event['version'] != 1) return;
      final generation = (event['generation'] as num?)?.toInt();
      final sequence = (event['sequence'] as num?)?.toInt();
      if (generation == null || sequence == null || generation < 0) return;
      if (generation < _generation ||
          (generation == _generation && sequence <= _sequence)) {
        return;
      }
      _generation = generation;
      _sequence = sequence;
      final type = event['type']?.toString() ?? '';
      if (!const <String>{
        'loading',
        'progress',
        'ready',
        'unready',
        'error',
      }.contains(type)) {
        return;
      }
      final payload = event['payload'] is Map
          ? Map<String, dynamic>.from(event['payload'] as Map)
          : const <String, dynamic>{};
      final shouldNotifyReady =
          type == 'ready' && _readyCallbackGeneration != generation;
      setState(() {
        switch (type) {
          case 'loading':
            _phase = _WebGLAvatarPhase.loading;
            _progress = null;
            _message = payload['message']?.toString() ?? '正在加载 3D 伙伴';
            break;
          case 'progress':
            _phase = _WebGLAvatarPhase.loading;
            _progress = ((payload['value'] as num?)?.toDouble() ?? 0).clamp(
              0.0,
              1.0,
            );
            _message = payload['message']?.toString() ?? '正在加载 3D 伙伴';
            break;
          case 'ready':
            _phase = _WebGLAvatarPhase.ready;
            _progress = 1;
            _message = '3D 伙伴已就绪';
            break;
          case 'unready':
            _phase = _WebGLAvatarPhase.loading;
            _progress = null;
            _message = payload['message']?.toString() ?? '正在恢复 3D 伙伴';
            break;
          case 'error':
            _phase = _WebGLAvatarPhase.error;
            _progress = null;
            _message = payload['message']?.toString() ?? '3D 伙伴加载失败';
            break;
        }
      });
      if (shouldNotifyReady) {
        _readyCallbackGeneration = generation;
        widget.onReady?.call();
      }
    } on FormatException {
      // Ignore malformed browser events; the last valid state stays visible.
    }
  }

  void _retry() {
    final host = _host ?? _maasoUnityAvatarHost;
    if (host == null) {
      setState(() {
        _phase = _WebGLAvatarPhase.error;
        _message = '3D 伙伴宿主未加载，请刷新页面';
      });
      return;
    }
    if (_host == null) {
      _connectHost();
    }
    setState(() {
      _phase = _WebGLAvatarPhase.loading;
      _progress = null;
      _message = '正在重新加载 3D 伙伴';
    });
    host.retry(_leaseId.toJS);
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.phase,
    required this.progress,
    required this.message,
    required this.onRetry,
  });

  final _WebGLAvatarPhase phase;
  final double? progress;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isError = phase == _WebGLAvatarPhase.error;
    final theme = Theme.of(context);
    final frost = MaasoGlassTheme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: frost.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(MaasoGlassTheme.surfaceRadius),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: frost.shadow,
              blurRadius: MaasoGlassTheme.staticShadowBlur,
              offset: MaasoGlassTheme.staticShadowOffset,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isError)
                Icon(
                  Icons.cloud_off_rounded,
                  size: 20,
                  color: theme.colorScheme.error,
                )
              else
                SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2.4,
                    color: theme.colorScheme.primary,
                  ),
                ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (isError) ...<Widget>[
                const SizedBox(width: 10),
                TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
