import 'package:flutter/material.dart';
import '../domain/cosmetic_appearance.dart';

/// Adds permanent visual styling around an existing typed identity badge.
/// The original name and Alien/Native role remain intact and accessible.
class CosmeticNameplate extends StatelessWidget {
  const CosmeticNameplate({
    required this.appearance,
    required this.child,
    this.chinese,
    this.foregroundColor,
    super.key,
  });
  final CosmeticAppearance appearance;
  final Widget child;
  final bool? chinese;
  final Color? foregroundColor;
  static List<Color> frameColors(String renderId) => switch (renderId) {
    'aurora' => const [Color(0xFFA78BFA), Color(0xFF34D399)],
    'solar' => const [Color(0xFFF59E0B), Color(0xFFFB7185)],
    'orbit' => const [Color(0xFF60A5FA), Color(0xFFC4B5FD)],
    _ => const [Colors.transparent, Colors.transparent],
  };
  @override
  Widget build(BuildContext context) {
    if (appearance.isEmpty) return child;
    final zh = chinese ?? Localizations.localeOf(context).languageCode == 'zh';
    final title = appearance.title;
    final foreground =
        foregroundColor ?? (appearance.frame == null ? null : Colors.white);
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DefaultTextStyle.merge(
          style: TextStyle(color: foreground),
          child: child,
        ),
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: title.renderId == 'ribbon'
                  ? BoxDecoration(
                      color: const Color(0xFF4F46E5),
                      borderRadius: BorderRadius.circular(5),
                    )
                  : null,
              child: Text(
                title.name(zh: zh),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: title.renderId == 'ribbon' ? Colors.white : foreground,
                ),
                semanticsLabel:
                    '${zh ? '装扮称号' : 'Cosmetic title'}: ${title.name(zh: zh)}',
              ),
            ),
          ),
      ],
    );
    if (appearance.frame != null) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: frameColors(appearance.frame!.renderId),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF17151D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: content,
          ),
        ),
      );
    }
    return content;
  }
}
