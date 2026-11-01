/// Conservative transcript guard for acoustic barge-in.
///
/// Acoustic echo cancellation can attenuate speaker playback without removing
/// every word. This guard compares the finalized ASR transcript with the exact
/// utterance owned by the paused player. It deliberately ignores very short
/// phrases: acknowledgements such as "嗯" and "ok" belong to the backchannel
/// classifier, while a short overlap is not enough evidence to discard user
/// speech.
final class BargeInSelfEchoGuard {
  const BargeInSelfEchoGuard({
    this.minimumComparableRunes = 4,
    this.minimumContainedRatio = 0.4,
    this.minimumBigramDice = 0.78,
  }) : assert(minimumComparableRunes > 0),
       assert(minimumContainedRatio > 0 && minimumContainedRatio <= 1),
       assert(minimumBigramDice > 0 && minimumBigramDice <= 1);

  final int minimumComparableRunes;
  final double minimumContainedRatio;
  final double minimumBigramDice;

  bool isLikelySelfEcho({
    required String transcript,
    required String spokenText,
  }) {
    final heard = _normalize(transcript);
    final spoken = _normalize(spokenText);
    final heardLength = heard.runes.length;
    final spokenLength = spoken.runes.length;
    if (heardLength < minimumComparableRunes ||
        spokenLength < minimumComparableRunes) {
      return false;
    }
    if (heard == spoken) return true;

    final shorter = heardLength < spokenLength ? heardLength : spokenLength;
    final longer = heardLength > spokenLength ? heardLength : spokenLength;
    final lengthRatio = shorter / longer;
    if (spoken.contains(heard) &&
        heardLength / spokenLength >= minimumContainedRatio) {
      return true;
    }
    // A transcript may add a tiny recognition artifact around the playback,
    // but substantial extra words are user intent and must remain audible.
    if (heard.contains(spoken) && heardLength <= spokenLength + 2) {
      return true;
    }
    if (lengthRatio < minimumContainedRatio) return false;

    return _bigramDice(heard, spoken) >= minimumBigramDice;
  }

  static String _normalize(String value) {
    final lower = value.toLowerCase();
    final output = StringBuffer();
    for (final rune in lower.runes) {
      if (_isComparableRune(rune)) output.writeCharCode(rune);
    }
    return output.toString();
  }

  static bool _isComparableRune(int rune) =>
      rune >= 0x30 && rune <= 0x39 ||
      rune >= 0x61 && rune <= 0x7a ||
      rune >= 0x3400 && rune <= 0x9fff ||
      rune >= 0x3040 && rune <= 0x30ff ||
      rune >= 0xac00 && rune <= 0xd7af;

  static double _bigramDice(String left, String right) {
    final leftBigrams = _bigrams(left);
    final rightBigrams = _bigrams(right);
    if (leftBigrams.isEmpty || rightBigrams.isEmpty) return 0;
    final remaining = <String, int>{};
    for (final item in rightBigrams) {
      remaining[item] = (remaining[item] ?? 0) + 1;
    }
    var overlap = 0;
    for (final item in leftBigrams) {
      final count = remaining[item] ?? 0;
      if (count == 0) continue;
      overlap++;
      remaining[item] = count - 1;
    }
    return 2 * overlap / (leftBigrams.length + rightBigrams.length);
  }

  static List<String> _bigrams(String value) {
    final runes = value.runes.toList(growable: false);
    if (runes.length < 2) return const <String>[];
    return <String>[
      for (var index = 0; index + 1 < runes.length; index++)
        String.fromCharCodes(<int>[runes[index], runes[index + 1]]),
    ];
  }
}
