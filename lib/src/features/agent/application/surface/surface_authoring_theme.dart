import 'dart:ui';

import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

/// Optional legacy theme helpers for explicitly styled surfaces.
///
/// User-generated game/Applet CSS is authoritative. The host app's visual
/// theme does not become a stylesheet inside a user's project. Existing saved
/// snapshots remain readable; built-in surfaces can still explicitly opt in.
abstract final class SurfaceAuthoringTheme {
  static const snapshotStart = '/* maaso-theme-snapshot:start */';
  static const snapshotEnd = '/* maaso-theme-snapshot:end */';

  static void applyToNewSource(Map<String, Object?> source) {
    // Retain this preparation seam for existing callers. New authored HTML,
    // CSS and JS pass through unchanged, including an intentionally empty CSS.
  }

  /// An explicit CSS edit may replace or remove an old snapshot. Reopening a
  /// saved project keeps its persisted source; editing must not resurrect it.
  static String preserveSnapshot(
    String previous,
    String authored, {
    bool? transparent,
  }) {
    return authored;
  }

  static String cssSnapshot({bool transparent = false}) {
    final background = transparent ? 'transparent' : 'var(--maaso-canvas)';
    const chromeBlur =
        '''
@supports ((backdrop-filter:blur(${MaasoFrostTokens.blurSigma}px)) or (-webkit-backdrop-filter:blur(${MaasoFrostTokens.blurSigma}px))){
:where(.maaso-frost-chrome){-webkit-backdrop-filter:var(--maaso-chrome-filter);backdrop-filter:var(--maaso-chrome-filter)}
}
''';
    return '''
$snapshotStart
:root{
--maaso-theme-id:"${MaasoFrostTokens.themeId}";
--maaso-theme-version:${MaasoFrostTokens.themeId.split('/v').last};
--maaso-root-background:$background;
--maaso-frost-blur:${MaasoFrostTokens.blurSigma}px;
--maaso-chrome-filter:${transparent ? 'none' : 'blur(var(--maaso-frost-blur))'};
${_colorVariables(dark: false)}
--maaso-radius-card:${MaasoFrostTokens.cardRadius}px;
--maaso-radius-input:${MaasoFrostTokens.inputRadius}px;
--maaso-radius-compact:${MaasoFrostTokens.compactRadius}px;
--maaso-radius-sheet:${MaasoFrostTokens.sheetRadius}px;
--maaso-radius-pill:${MaasoFrostTokens.pillRadius}px;
--maaso-touch-min:${MaasoFrostTokens.touchMin}px;
--maaso-motion-pressed:${MaasoFrostTokens.motionPressed.inMilliseconds}ms;
--maaso-motion-segment:${MaasoFrostTokens.motionSegment.inMilliseconds}ms;
--maaso-motion-panel:${MaasoFrostTokens.motionPanel.inMilliseconds}ms;
--maaso-frost-shadow:0 3px 14px rgba(16,18,22,.06);
color-scheme:light;
}
@media(prefers-color-scheme:dark){:root{${_colorVariables(dark: true)}color-scheme:dark;}}
html,body{margin:0;background:var(--maaso-root-background);color:var(--maaso-text-primary);font:400 15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
:where(*,*::before,*::after){box-sizing:border-box}
:where(button,input,textarea,select){font:inherit;color:inherit}
:where(button,[role="button"],a,input,textarea,select){-webkit-tap-highlight-color:transparent}
:where(button,[role="button"]){min-width:var(--maaso-touch-min);min-height:var(--maaso-touch-min);padding:12px 20px;border:0;border-radius:var(--maaso-radius-pill);background:var(--maaso-action);color:var(--maaso-on-action);cursor:pointer;touch-action:manipulation;transition:opacity var(--maaso-motion-pressed)}
:where(button:active){opacity:.82}
:where(button:disabled){opacity:.45;cursor:not-allowed}
:where(input:not([type="checkbox"]):not([type="radio"]):not([type="range"]),textarea,select,.maaso-input){min-height:var(--maaso-touch-min);padding:12px 16px;border:0;border-radius:var(--maaso-radius-input);background:var(--maaso-input-fill);box-shadow:var(--maaso-frost-shadow);color:var(--maaso-text-primary)}
:where(input,textarea)::placeholder{color:var(--maaso-text-secondary)}
:where(button,input,textarea,select,[tabindex]):focus-visible{outline:3px solid var(--maaso-accent);outline-offset:3px}
:where(.maaso-surface){background:var(--maaso-canvas);color:var(--maaso-text-primary)}
:where(.maaso-card){padding:24px;border:0;border-radius:var(--maaso-radius-card);background:var(--maaso-muted)}
:where(.maaso-capsule,.maaso-secondary,.maaso-segmented){border:0;border-radius:var(--maaso-radius-pill);background:var(--maaso-capsule-fill);color:var(--maaso-text-primary);box-shadow:var(--maaso-frost-shadow)}
:where(.maaso-segmented){display:flex;gap:4px;padding:4px;min-height:56px}
:where(.maaso-segmented>button){flex:1;min-width:0;background:transparent;color:var(--maaso-text-secondary)}
:where(.maaso-segmented>[aria-selected="true"],.maaso-segmented>[aria-pressed="true"]){background:var(--maaso-surface);color:var(--maaso-accent);font-weight:600}
:where(.maaso-muted){color:var(--maaso-text-secondary)}
:where(.maaso-error,[role="alert"]){color:var(--maaso-danger)}
$chromeBlur
@media(prefers-reduced-transparency:reduce),(prefers-contrast:more){:root{--maaso-capsule-fill:var(--maaso-surface);--maaso-input-fill:var(--maaso-surface)}:where(.maaso-frost-chrome){-webkit-backdrop-filter:none;backdrop-filter:none}}
@media(prefers-reduced-motion:reduce){:root{--maaso-motion-pressed:0ms;--maaso-motion-segment:0ms;--maaso-motion-panel:0ms}}
@media(max-width:360px){:where(.maaso-segmented){flex-direction:column;border-radius:var(--maaso-radius-card)}:where(.maaso-segmented>button){flex:auto}}
$snapshotEnd''';
  }

  static String _colorVariables({required bool dark}) {
    final surface = dark
        ? MaasoFrostTokens.darkSurface
        : MaasoFrostTokens.lightSurface;
    final colors = <String, Color>{
      'canvas': dark
          ? MaasoFrostTokens.darkCanvas
          : MaasoFrostTokens.lightCanvas,
      'surface': surface,
      'muted': dark ? MaasoFrostTokens.darkMuted : MaasoFrostTokens.lightMuted,
      'text-primary': dark
          ? MaasoFrostTokens.darkTextPrimary
          : MaasoFrostTokens.lightTextPrimary,
      'text-secondary': dark
          ? MaasoFrostTokens.darkTextSecondary
          : MaasoFrostTokens.lightTextSecondary,
      'action': MaasoFrostTokens.action,
      'on-action': MaasoFrostTokens.onAction,
      'accent': dark
          ? MaasoFrostTokens.darkAccent
          : MaasoFrostTokens.lightAccent,
      'accent-soft': dark
          ? MaasoFrostTokens.darkAccentSoft
          : MaasoFrostTokens.lightAccentSoft,
      'divider': dark
          ? MaasoFrostTokens.darkDivider
          : MaasoFrostTokens.lightDivider,
      'success': dark
          ? MaasoFrostTokens.darkSuccess
          : MaasoFrostTokens.lightSuccess,
      'danger': dark
          ? MaasoFrostTokens.darkDanger
          : MaasoFrostTokens.lightDanger,
    };
    return '${colors.entries.map((entry) => '--maaso-${entry.key}:${_hex(entry.value)};').join('\n')}\n'
        '--maaso-capsule-fill:${_rgba(surface, MaasoFrostTokens.capsuleFillAlpha)};\n'
        '--maaso-input-fill:${_rgba(surface, MaasoFrostTokens.inputFillAlpha)};\n';
  }

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static String _rgba(Color color, double alpha) {
    final value = color.toARGB32();
    return 'rgba(${(value >> 16) & 255},${(value >> 8) & 255},${value & 255},$alpha)';
  }
}
