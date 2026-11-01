import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';

/// Home's transparent, genuine-text platform editor.
/// Its transparent text editor adds no material or background sampling.
class HomeNativeTextEditor extends StatefulWidget {
  const HomeNativeTextEditor({
    super.key,
    required this.bridge,
    this.fontSize = 16,
  });

  final HomeNativeTextEditingBridge bridge;
  final double fontSize;

  @override
  State<HomeNativeTextEditor> createState() => _HomeNativeTextEditorState();
}

class _HomeNativeTextEditorState extends State<HomeNativeTextEditor> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateStyle();
  }

  @override
  void didUpdateWidget(covariant HomeNativeTextEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bridge != widget.bridge) oldWidget.bridge.detachView();
    _updateStyle();
  }

  void _updateStyle() {
    final glass = MaasoGlassTheme.of(context);
    widget.bridge.setStyle(
      fontSize: MediaQuery.textScalerOf(context).scale(widget.fontSize),
      dark: Theme.of(context).brightness == Brightness.dark,
      textColorArgb: glass.foregroundPrimary.toARGB32(),
      cursorColorArgb: glass.action.toARGB32(),
      selectionColorArgb: glass.action.withValues(alpha: .28).toARGB32(),
    );
  }

  @override
  void dispose() {
    widget.bridge.detachView();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final params = widget.bridge.creationParams(
      fontSize: MediaQuery.textScalerOf(context).scale(widget.fontSize),
      dark: Theme.of(context).brightness == Brightness.dark,
    );
    final key = ValueKey(widget.bridge);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        key: key,
        viewType: HomeNativeTextEditingBridge.viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: widget.bridge.attachView,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        key: key,
        viewType: HomeNativeTextEditingBridge.viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: widget.bridge.attachView,
      );
    }
    return const Center(
      child: Text('Native editor probe requires iOS or Android.'),
    );
  }
}
