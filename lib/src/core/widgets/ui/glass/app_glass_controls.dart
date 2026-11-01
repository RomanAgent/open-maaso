import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

class AppGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppGlassAppBar({
    this.title,
    this.titleWidget,
    this.leading,
    this.actions = const <Widget>[],
    this.centerTitle = true,
    this.height = 52,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    super.key,
  }) : assert(title != null || titleWidget != null);

  final String? title;
  final Widget? titleWidget;
  final Widget? leading;
  final List<Widget> actions;
  final bool centerTitle;
  final double height;
  final EdgeInsetsGeometry margin;

  @override
  Size get preferredSize => Size.fromHeight(height + 12);

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final resolvedTitle =
        titleWidget ??
        Text(
          title!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.35,
          ),
        );
    return AppGlassSurface(
      role: AppGlassSurfaceRole.chrome,
      behavior: AppGlassSurfaceBehavior.automatic,
      margin: margin,
      height: height,
      child: NavigationToolbar(
        middle: Semantics(header: true, child: resolvedTitle),
        leading: leading == null
            ? null
            : SizedBox(width: MaasoGlassTheme.controlTarget, child: leading),
        trailing: actions.isEmpty
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: actions),
        centerMiddle: centerTitle,
        middleSpacing: 12,
      ),
    );
  }
}

class AppGlassButton extends StatelessWidget {
  const AppGlassButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = true,
    this.fullWidth = false,
    this.color,
    this.foregroundColor,
    this.minHeight = 50,
    this.semanticLabel,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool fullWidth;
  final Color? color;
  final Color? foregroundColor;
  final double minHeight;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final foreground =
        foregroundColor ?? (primary ? glass.onAction : glass.foregroundPrimary);
    final tint = color ?? (primary ? glass.action : null);
    final height = minHeight.clamp(MaasoGlassTheme.controlTarget, 80.0);
    final content = Row(
      mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 19, color: foreground),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: foreground,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              height: 20 / 15,
            ),
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel ?? label,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.control,
          tintColor: tint,
          width: fullWidth ? double.infinity : null,
          constraints: BoxConstraints(
            minWidth: MaasoGlassTheme.controlTarget,
            minHeight: height,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(
                MaasoGlassTheme.capsuleRadius,
              ),
              child: Opacity(
                opacity: onPressed == null ? 0.46 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppGlassIconButton extends StatelessWidget {
  const AppGlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.size = MaasoGlassTheme.controlTarget,
    this.iconSize = 22,
    this.color,
    this.foregroundColor,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final effectiveSize = size.clamp(MaasoGlassTheme.controlTarget, 96.0);
    final tint = color ?? (selected ? glass.action : null);
    final foreground =
        foregroundColor ??
        (selected ? glass.onAction : glass.foregroundPrimary);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        selected: selected,
        label: tooltip,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: AppGlassSurface(
            role: AppGlassSurfaceRole.control,
            tintColor: tint,
            width: effectiveSize,
            height: effectiveSize,
            child: IconButton(
              onPressed: onPressed,
              icon: Icon(
                icon,
                size: iconSize,
                color: onPressed == null
                    ? foreground.withValues(alpha: 0.46)
                    : foreground,
              ),
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(
                width: effectiveSize,
                height: effectiveSize,
              ),
              style: IconButton.styleFrom(shape: const CircleBorder()),
            ),
          ),
        ),
      ),
    );
  }
}

class AppGlassBackButton extends StatelessWidget {
  const AppGlassBackButton({
    required this.onPressed,
    this.tooltip = 'common.back',
    super.key,
  });

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return AppGlassIconButton(
      icon: Icons.arrow_back_rounded,
      tooltip: tooltip.tr,
      onPressed: onPressed,
      size: 48,
      iconSize: 23,
    );
  }
}

class AppGlassPageHeader extends StatelessWidget {
  const AppGlassPageHeader({
    required this.title,
    required this.onBack,
    this.backTooltip = 'common.back',
    this.trailing,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final String backTooltip;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: <Widget>[
        AppGlassBackButton(onPressed: onBack, tooltip: backTooltip),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.15,
              letterSpacing: -0.35,
            ),
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class AppGlassChip extends StatelessWidget {
  const AppGlassChip({
    required this.label,
    this.onTap,
    this.selected = false,
    this.icon,
    this.behavior = AppGlassSurfaceBehavior.staticSurface,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final IconData? icon;
  final AppGlassSurfaceBehavior behavior;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final foreground = selected ? glass.accentText : glass.foregroundPrimary;
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      selected: selected,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.control,
          behavior: behavior,
          tintColor: selected ? glass.accentSoft : null,
          constraints: const BoxConstraints(
            minWidth: MaasoGlassTheme.controlTarget,
            minHeight: MaasoGlassTheme.controlTarget,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(
                MaasoGlassTheme.capsuleRadius,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      Icon(icon, size: 20, color: foreground),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 20 / 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppGlassField extends StatelessWidget {
  const AppGlassField({
    this.controller,
    this.focusNode,
    this.hintText,
    this.labelText,
    this.prefixIcon,
    this.prefix,
    this.suffix,
    this.obscureText = false,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = false,
    this.autofillHints,
    this.inputFormatters,
    this.enabled = true,
    this.readOnly = false,
    this.enableSuggestions = true,
    this.autocorrect = true,
    this.glassShell = true,
    this.blur = false,
    this.decoration,
    super.key,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final String? labelText;
  final IconData? prefixIcon;
  final Widget? prefix;
  final Widget? suffix;
  final bool obscureText;
  final TextInputType? keyboardType;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onTap;
  final TapRegionCallback? onTapOutside;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final bool autofocus;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final bool readOnly;
  final bool enableSuggestions;
  final bool autocorrect;
  final bool glassShell;

  /// Opt in only for a bounded, non-scrolling input with a page blur budget.
  final bool blur;
  final InputDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final editor = Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          keyboardType: keyboardType,
          maxLines: maxLines,
          minLines: minLines,
          maxLength: maxLength,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          onEditingComplete: onEditingComplete,
          onTap: onTap,
          onTapOutside: onTapOutside,
          textInputAction: textInputAction,
          textCapitalization: textCapitalization,
          autofocus: autofocus,
          autofillHints: autofillHints,
          inputFormatters: inputFormatters,
          enabled: enabled,
          readOnly: readOnly,
          enableSuggestions: enableSuggestions,
          autocorrect: autocorrect,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontSize: 16,
            height: 1.25,
            fontWeight: FontWeight.w400,
          ),
          decoration: (decoration ?? const InputDecoration()).copyWith(
            filled: false,
            fillColor: Colors.transparent,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            hintText: hintText ?? decoration?.hintText,
            labelText: labelText ?? decoration?.labelText,
            prefixIcon:
                prefix ??
                (prefixIcon == null
                    ? decoration?.prefixIcon
                    : Icon(
                        prefixIcon,
                        size: 18,
                        color: glass.foregroundSecondary,
                      )),
            suffixIcon: suffix ?? decoration?.suffixIcon,
            hintStyle: TextStyle(color: glass.foregroundSecondary),
            labelStyle: TextStyle(color: glass.foregroundSecondary),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            counterText: '',
          ),
        ),
      ),
    );
    if (!glassShell) return editor;
    return AppGlassSurface(
      role: AppGlassSurfaceRole.field,
      blur: blur,
      behavior: AppGlassSurfaceBehavior.automatic,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: editor,
    );
  }
}
