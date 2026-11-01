final class AgentGameRevisionSummary {
  const AgentGameRevisionSummary({
    required this.revisionNo,
    required this.sourceSha256,
    required this.createdAt,
  });
  final int revisionNo;
  final String sourceSha256;
  final DateTime createdAt;

  factory AgentGameRevisionSummary.fromJson(Map raw) {
    final number = raw['revisionNo'];
    final hash = raw['sourceSha256'];
    final created = DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    if (number is! int ||
        number < 1 ||
        number > 1000 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        created == null) {
      throw const FormatException('applet_version_history_invalid');
    }
    return AgentGameRevisionSummary(
      revisionNo: number,
      sourceSha256: hash,
      createdAt: created,
    );
  }
}

final class AgentGameRevisionPage {
  AgentGameRevisionPage({
    required this.gameId,
    required this.clientSurfaceId,
    required this.currentRevisionNo,
    required this.publishedRevisionNo,
    required List<AgentGameRevisionSummary> items,
    this.nextBeforeRevision,
  }) : items = List.unmodifiable(items);
  final String gameId;
  final String clientSurfaceId;
  final int currentRevisionNo;
  final int? publishedRevisionNo;
  final List<AgentGameRevisionSummary> items;
  final int? nextBeforeRevision;

  factory AgentGameRevisionPage.fromJson(Map raw) {
    final current = raw['currentRevisionNo'];
    final published = raw['publishedRevisionNo'];
    final next = raw['nextBeforeRevision'];
    final items = raw['items'];
    if (raw['gameId'] is! String ||
        raw['clientSurfaceId'] is! String ||
        current is! int ||
        current < 1 ||
        current > 1000 ||
        (published != null &&
            (published is! int || published < 1 || published > current)) ||
        (next != null && (next is! int || next < 1 || next > current)) ||
        items is! List ||
        items.length > 100) {
      throw const FormatException('applet_version_history_invalid');
    }
    final parsed = items
        .map((item) => AgentGameRevisionSummary.fromJson(item as Map))
        .toList();
    var previous = current + 1;
    for (final item in parsed) {
      if (item.revisionNo >= previous) {
        throw const FormatException('applet_version_history_invalid');
      }
      previous = item.revisionNo;
    }
    if (next != null && (parsed.isEmpty || next != parsed.last.revisionNo)) {
      throw const FormatException('applet_version_history_invalid');
    }
    return AgentGameRevisionPage(
      gameId: raw['gameId'] as String,
      clientSurfaceId: raw['clientSurfaceId'] as String,
      currentRevisionNo: current,
      publishedRevisionNo: published as int?,
      items: parsed,
      nextBeforeRevision: next as int?,
    );
  }
}

final class AppletVersionConflictException implements Exception {
  const AppletVersionConflictException();
  @override
  String toString() => 'applet_version_conflict';
}
