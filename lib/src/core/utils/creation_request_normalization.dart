/// Removes only the existing literal image-reference/regeneration preamble.
/// Callers must still validate the current user's affirmative request.
String normalizeCreationRequest(String text) {
  var value = text.trim();
  value = value.replaceFirst(
    RegExp(
      r'^(?:(?:请|麻烦)(?:你)?(?:帮我)?|帮我|给我)?(?:参考|根据|按照|照着)(?:(?:这|那|所附|上传的|我上传的|我发的|附件里的)(?:[一二三四1-4])?(?:张|个|些)?)?(?:参考图|图片|截图|图)(?:的(?:风格|布局|样式))?[\s，,：:]*',
    ),
    '',
  );
  value = value.replaceFirst(
    RegExp(
      r'^(?:based on|using|following)\s+(?:(?:this|these|the)\s+)?(?:(?:attached|uploaded|reference)\s+)?(?:images?|photos?|screenshots?)(?:\s+(?:layout|style))?[\s,:-]*',
      caseSensitive: false,
    ),
    '',
  );
  return value
      .trim()
      .replaceFirst(RegExp(r'^(?:重新|再)(?=生成|创建|制作|开发|做一个|做个)'), '')
      .replaceFirst(RegExp(r'^regenerate\b', caseSensitive: false), 'generate');
}
