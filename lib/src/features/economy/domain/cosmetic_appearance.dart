/// Public appearance only. There are no account, ownership, price or wallet
/// identifiers in this model; it is shared by world and content nameplates.
final class CosmeticStyle {
  const CosmeticStyle({
    required this.kind,
    required this.renderId,
    required this.nameEn,
    required this.nameZh,
  });
  final String kind, renderId, nameEn, nameZh;
  String name({required bool zh}) => zh ? nameZh : nameEn;
  factory CosmeticStyle.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('invalid_cosmetic_style');
    }
    final kind = value['kind'], render = value['renderId'];
    final validRender = switch (kind) {
      'frame' => const {'aurora', 'solar', 'orbit'}.contains(render),
      'title' => const {'plain', 'ribbon'}.contains(render),
      _ => false,
    };
    bool name(Object? s) =>
        s is String &&
        s.isNotEmpty &&
        s == s.trim() &&
        s.runes.length <= 32 &&
        !RegExp(r'[\u0000-\u001F\u007F<>]').hasMatch(s);
    if (!validRender || !name(value['nameEn']) || !name(value['nameZh'])) {
      throw const FormatException('unsupported_cosmetic_style');
    }
    return CosmeticStyle(
      kind: kind as String,
      renderId: render as String,
      nameEn: value['nameEn'] as String,
      nameZh: value['nameZh'] as String,
    );
  }
  Map<String, String> toJson() => {
    'kind': kind,
    'renderId': renderId,
    'nameEn': nameEn,
    'nameZh': nameZh,
  };
}

final class CosmeticAppearance {
  const CosmeticAppearance({this.frame, this.title});
  final CosmeticStyle? frame, title;
  bool get isEmpty => frame == null && title == null;
  factory CosmeticAppearance.fromJson(Object? value) {
    if (value == null) return const CosmeticAppearance();
    if (value is! Map<String, dynamic>) {
      throw const FormatException('invalid_cosmetic_appearance');
    }
    final frame = value['frame'] == null
        ? null
        : CosmeticStyle.fromJson(value['frame']);
    final title = value['title'] == null
        ? null
        : CosmeticStyle.fromJson(value['title']);
    if ((frame != null && frame.kind != 'frame') ||
        (title != null && title.kind != 'title')) {
      throw const FormatException('invalid_cosmetic_slot');
    }
    return CosmeticAppearance(frame: frame, title: title);
  }
  Map<String, Object> toJson() => {
    if (frame != null) 'frame': frame!.toJson(),
    if (title != null) 'title': title!.toJson(),
  };
}
