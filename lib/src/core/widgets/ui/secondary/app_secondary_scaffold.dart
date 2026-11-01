import 'package:flutter/material.dart';

import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';

class AppSecondaryScaffold extends StatelessWidget {
  const AppSecondaryScaffold({
    super.key,
    required this.header,
    required this.body,
    this.bottomBar,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset = true,
    this.safeAreaBottom = true,
    this.contentMaxWidth,
  }) : assert(
         contentMaxWidth == null || contentMaxWidth > 0,
         'contentMaxWidth must be greater than zero.',
       );

  static const backgroundKey = ValueKey<String>('app-secondary-background');
  static const contentFrameKey = ValueKey<String>(
    'app-secondary-content-frame',
  );

  final Widget header;
  final Widget body;
  final Widget? bottomBar;
  final Widget? floatingActionButton;
  final bool resizeToAvoidBottomInset;
  final bool safeAreaBottom;
  final double? contentMaxWidth;

  @override
  Widget build(BuildContext context) {
    return AppGlassScaffold(
      backdropKind: GlassBackdropKind.flutter,
      safeArea: false,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      background: const AppSecondaryBackground(),
      body: Column(
        children: <Widget>[
          SafeArea(bottom: false, child: header),
          Expanded(
            child: SafeArea(
              top: false,
              bottom: safeAreaBottom,
              child: _bodyFrame(),
            ),
          ),
        ],
      ),
      bottomNavigationBar: bottomBar == null
          ? null
          : AppSecondaryBottomBar(child: bottomBar!),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _bodyFrame() {
    final maxWidth = contentMaxWidth;
    if (maxWidth == null) return body;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            key: contentFrameKey,
            width: constraints.constrainWidth(maxWidth),
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            child: body,
          ),
        );
      },
    );
  }
}

class AppSecondaryBackground extends StatelessWidget {
  const AppSecondaryBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = AppSecondaryPalette.of(context);
    return DecoratedBox(
      key: AppSecondaryScaffold.backgroundKey,
      decoration: BoxDecoration(color: palette.backgroundStart),
    );
  }
}

class AppSecondaryBottomBar extends StatelessWidget {
  const AppSecondaryBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = AppSecondaryPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: palette.surface),
      child: SafeArea(top: false, child: child),
    );
  }
}

class AppSecondaryHeader extends StatelessWidget {
  const AppSecondaryHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.titleLeading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? titleLeading;
  final Widget? trailing;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Row(
        children: <Widget>[
          AppGlassIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'common.back'.tr,
            onPressed: onBack,
            size: 48,
            iconSize: 22,
          ),
          const SizedBox(width: 10),
          if (titleLeading != null) ...<Widget>[
            titleLeading!,
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 24,
                    height: 32 / 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}
