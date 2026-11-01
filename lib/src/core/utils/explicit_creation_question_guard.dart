/// Fail-closed language guard for questions that mention creation without
/// authorizing it.
///
/// Positive intent classifiers remain responsible for their own product and
/// action vocabulary. This guard only identifies informational and comparative
/// question shapes, so polite requests such as “Can you create a game?” remain
/// eligible for the caller's explicit-creation rules.
final class ExplicitCreationQuestionGuard {
  const ExplicitCreationQuestionGuard._();

  static bool blocks(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return false;

    if (RegExp(
      r'^(?:what|how|why|when|where|which|who)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'^(?:什么是|如何|怎么|为什么|怎样|哪个|哪种)').hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'\b(?:explain|describe|compare|teach|tell|show|help(?: me)? understand)\b.*\b(?:what|how|why|which|whether)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'(?:解释|说明|比较|介绍|教我|告诉我|让我了解).*(?:什么|如何|怎么|为什么|哪个|哪些|是否)',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'\b(?:is it|would it be)\s+(?:better|safer|faster|easier|cheaper)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'\b(?:which|what)\b.*\b(?:better|best|safer|faster|easier|cheaper|preferable)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'^(?:is|are|was|were|would|should)\b.*\b(?:better|safer|faster|easier|cheaper|preferable)\b.*\b(?:or|than)\b',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(
      r'(?:还是|或者).{0,40}(?:更好|更合适|更适合|更安全|更便宜|更快|更容易|比较好)|(?:哪个|哪种).{0,20}(?:更|比较)|孰(?:优|劣|更|好)|(?:怎么|如何)(?:选|选择)|选(?:哪个|哪种)',
    ).hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'(?:会怎样|会怎么样)[?？。.]?$').hasMatch(normalized)) {
      return true;
    }
    return RegExp(
      r'(?:要|需要|应该|可以|能|会|得).*(?:什么|多久|多长|怎么|如何|哪些|多少|注意什么)[?？。.]?$',
    ).hasMatch(normalized);
  }
}
