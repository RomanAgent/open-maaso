import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';

class AppGlassComposer extends StatelessWidget {
  const AppGlassComposer({
    required this.field,
    required this.trailing,
    this.leading,
    this.footer,
    this.padding = const EdgeInsets.all(8),
    this.gap = 8,
    super.key,
  });

  final Widget field;
  final Widget trailing;
  final Widget? leading;
  final Widget? footer;
  final EdgeInsetsGeometry padding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.chrome,
      behavior: AppGlassSurfaceBehavior.automatic,
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (leading != null) ...<Widget>[leading!, SizedBox(width: gap)],
              Expanded(child: field),
              SizedBox(width: gap),
              trailing,
            ],
          ),
          if (footer != null) ...<Widget>[SizedBox(height: gap), footer!],
        ],
      ),
    );
  }
}
