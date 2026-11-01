import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

/// Settings groups use the shared static frost material, without backdrop blur.
class SettingsFrostPanel extends StatelessWidget {
  const SettingsFrostPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: MaasoGlassTheme.of(context).muted,
    borderRadius: BorderRadius.circular(MaasoGlassTheme.surfaceRadius),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    ),
  );
}

class SettingsFrostGroup extends StatelessWidget {
  const SettingsFrostGroup({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            height: 20 / 13,
            fontWeight: FontWeight.w500,
            color: MaasoGlassTheme.of(context).foregroundSecondary,
          ),
        ),
      ),
      SettingsFrostPanel(key: ValueKey('settings-group-$title'), child: child),
    ],
  );
}

class SettingsFrostDivider extends StatelessWidget {
  const SettingsFrostDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: .5,
    indent: 34,
    color: MaasoGlassTheme.of(context).divider,
  );
}

class SettingsFrostRow extends StatelessWidget {
  const SettingsFrostRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(
                        icon,
                        size: 20,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final stacked =
                            constraints.maxWidth < 210 ||
                            MediaQuery.textScalerOf(context).scale(15) > 20;
                        final label = Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            height: 24 / 15,
                            fontWeight: FontWeight.w500,
                            color: glass.foregroundPrimary,
                          ),
                        );
                        final detail = value == null
                            ? null
                            : Text(
                                value!,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 20 / 13,
                                  color: glass.foregroundSecondary,
                                ),
                              );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (stacked) ...[
                              label,
                              ?detail,
                            ] else
                              Row(
                                children: [
                                  Expanded(child: label),
                                  if (detail != null) ...[
                                    const SizedBox(width: 12),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: constraints.maxWidth * .45,
                                      ),
                                      child: detail,
                                    ),
                                  ],
                                ],
                              ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 20 / 13,
                                  color: glass.foregroundSecondary,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: glass.foregroundSecondary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keep native switch semantics and the existing SwitchListTile test boundary.
class SettingsFrostSwitch extends StatelessWidget {
  const SettingsFrostSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.tileKey,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return SwitchListTile.adaptive(
      key: tileKey,
      activeTrackColor: glass.action,
      activeThumbColor: glass.onAction,
      inactiveTrackColor: glass.divider,
      inactiveThumbColor: glass.onAction,
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      secondary: SizedBox(
        width: 20,
        child: Icon(icon, size: 20, color: glass.foregroundSecondary),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          height: 24 / 15,
          fontWeight: FontWeight.w500,
          color: glass.foregroundPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(
                fontSize: 13,
                height: 20 / 13,
                color: glass.foregroundSecondary,
              ),
              child: subtitle!,
            ),
      value: value,
      onChanged: onChanged,
    );
  }
}

Future<T?> showSettingsChoiceSheet<T>({
  required BuildContext context,
  required Key sheetKey,
  required String title,
  required T selected,
  required List<T> values,
  required String Function(T) label,
  required String Function(T) keyName,
  required IconData Function(T) icon,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: MaasoGlassTheme.of(context).surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (context) {
    final glass = MaasoGlassTheme.of(context);
    return SafeArea(
      key: sheetKey,
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 22,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: glass.foregroundPrimary,
              ),
            ),
            const SizedBox(height: 16),
            SettingsFrostPanel(
              child: Column(
                children: [
                  for (final value in values)
                    ListTile(
                      key: ValueKey(keyName(value)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      leading: Icon(icon(value), size: 22),
                      title: Text(label(value)),
                      selected: value == selected,
                      selectedColor: glass.action,
                      trailing: value == selected
                          ? Icon(Icons.check_rounded, color: glass.action)
                          : null,
                      onTap: () => Navigator.of(context).pop(value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);
