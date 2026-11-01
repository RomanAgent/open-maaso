/// Shared text sanitizers for agent output.
library;

/// Matches the common emoji / pictograph code-point blocks plus the joiners
/// and variation selectors that glue compound emoji together.  Deliberately
/// broad — chat replies should be plain text, so we'd rather over-strip a
/// stray symbol than let an emoji slip into the bubble or the TTS voice.
final RegExp _emojiPattern = RegExp(
  r'[\u{1F000}-\u{1FAFF}]' // emoji, pictographs, symbols, transport, supplemental
  r'|[\u{2600}-\u{27BF}]' // misc symbols + dingbats
  r'|[\u{2300}-\u{23FF}]' // misc technical (⌚ ⏰ ⏳ …)
  r'|[\u{2B00}-\u{2BFF}]' // misc symbols & arrows (⭐ ⬛ …)
  r'|[\u{1F1E6}-\u{1F1FF}]' // regional indicators (flags)
  r'|[\u{FE00}-\u{FE0F}]' // variation selectors
  r'|\u{20E3}' // combining enclosing keycap
  r'|\u{200D}', // zero-width joiner
  unicode: true,
);

/// Remove emoji from [text] and tidy up the whitespace left behind.
String stripEmoji(String text) {
  if (text.isEmpty) return text;
  final stripped = text.replaceAll(_emojiPattern, '');
  // Collapse runs of spaces/tabs an emoji left behind, but keep newlines.
  return stripped.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
}

/// Remove emoji from a streamed text delta without trimming meaningful
/// boundary whitespace. Stream providers may emit spaces as standalone chunks.
String stripEmojiFromDelta(String text) {
  if (text.isEmpty) return text;
  return text.replaceAll(_emojiPattern, '');
}
