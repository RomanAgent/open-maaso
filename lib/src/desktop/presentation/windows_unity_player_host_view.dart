import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WindowsUnityPlayerHostView extends StatefulWidget {
  const WindowsUnityPlayerHostView({required this.fallback, super.key});

  static const channelName = 'maaso/desktop_unity_host';
  static const fallbackKey = ValueKey<String>('windows-unity-host-fallback');

  final Widget fallback;

  @override
  State<WindowsUnityPlayerHostView> createState() =>
      _WindowsUnityPlayerHostViewState();
}

class _WindowsUnityPlayerHostViewState extends State<WindowsUnityPlayerHostView>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel(WindowsUnityPlayerHostView.channelName);

  Rect? _lastPhysicalBounds;
  bool _syncScheduled = false;
  bool _started = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleBoundsSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleBoundsSync();
  }

  @override
  void didChangeMetrics() {
    _lastPhysicalBounds = null;
    _scheduleBoundsSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started || _closed) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_invoke<void>('resume'));
      _scheduleBoundsSync();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_invoke<void>('suspend'));
    }
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_invoke<void>('stop'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleBoundsSync();
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (!_started)
          KeyedSubtree(
            key: WindowsUnityPlayerHostView.fallbackKey,
            child: widget.fallback,
          ),
      ],
    );
  }

  void _scheduleBoundsSync() {
    if (_syncScheduled || _closed) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted || _closed) return;
      unawaited(_syncBounds());
    });
  }

  Future<void> _syncBounds() async {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) return;
    final origin = renderObject.localToGlobal(Offset.zero);
    final ratio = View.of(context).devicePixelRatio;
    final bounds = Rect.fromLTWH(
      (origin.dx * ratio).roundToDouble(),
      (origin.dy * ratio).roundToDouble(),
      (size.width * ratio).roundToDouble(),
      (size.height * ratio).roundToDouble(),
    );
    if (bounds == _lastPhysicalBounds) return;

    final arguments = <String, int>{
      'left': bounds.left.round(),
      'top': bounds.top.round(),
      'width': bounds.width.round(),
      'height': bounds.height.round(),
    };
    try {
      if (_started) {
        await _channel.invokeMethod<void>('setBounds', arguments);
      } else {
        final result = await _channel.invokeMapMethod<String, Object?>(
          'start',
          arguments,
        );
        if (result?['running'] == true && mounted && !_closed) {
          setState(() => _started = true);
        }
      }
      _lastPhysicalBounds = bounds;
    } on MissingPluginException {
      _debugLog('Windows Unity host channel is unavailable.');
    } on PlatformException catch (error) {
      _debugLog('Windows Unity host rejected bounds: ${error.code}');
    }
  }

  Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      _debugLog('Windows Unity host $method failed: ${error.code}');
      return null;
    }
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint('[DesktopUnityHost] $message');
  }
}
