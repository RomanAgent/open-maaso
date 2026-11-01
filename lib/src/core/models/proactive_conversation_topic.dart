import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:maaso/src/core/models/episode.dart';

enum ProactiveConversationScope { openTopics, everyday }

enum ProactiveTopicStatus { open, completed, revoked }

/// A one-time contact agreement, not a reminder or a relationship inference.
final class ProactiveConversationTopic {
  const ProactiveConversationTopic({
    required this.id,
    required this.label,
    required this.source,
    this.agentId = 'self',
    this.ownerKey,
    required this.dueAt,
    required this.expiresAt,
    this.status = ProactiveTopicStatus.open,
  });
  final String id;
  final String label;
  final EpisodeSourceRef source;
  final String agentId;
  final String? ownerKey;
  final DateTime dueAt;
  final DateTime expiresAt;
  final ProactiveTopicStatus status;
  String get topicKey => 'conversation.followup.$id';
  bool openAt(DateTime now) =>
      status == ProactiveTopicStatus.open && now.isBefore(expiresAt);
  bool dueAtTime(DateTime now) => openAt(now) && !now.isBefore(dueAt);
  ProactiveConversationTopic close(ProactiveTopicStatus status) =>
      ProactiveConversationTopic(
        id: id,
        label: label,
        source: source,
        agentId: agentId,
        ownerKey: ownerKey,
        dueAt: dueAt,
        expiresAt: expiresAt,
        status: status,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'source': source.toJson(),
    'agentId': agentId,
    'ownerKey': ownerKey,
    'dueAt': dueAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'status': status.name,
  };
  factory ProactiveConversationTopic.fromJson(Object? value) {
    if (value is! Map || value.length != 8) {
      throw const FormatException('invalid followup');
    }
    final id = value['id'];
    final label = value['label'];
    final source = EpisodeSourceRef.fromJson(value['source']);
    final agentId = value['agentId'];
    final ownerKey = value['ownerKey'];
    final due = DateTime.tryParse(value['dueAt']?.toString() ?? '');
    final expiry = DateTime.tryParse(value['expiresAt']?.toString() ?? '');
    final status = ProactiveTopicStatus.values
        .where((s) => s.name == value['status'])
        .firstOrNull;
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        label is! String ||
        label.length < 2 ||
        label.length > 40 ||
        RegExp(r'[<>`\r\n]').hasMatch(label) ||
        (ownerKey != null &&
            (ownerKey is! String ||
                ownerKey.length > 180 ||
                ownerKey.isEmpty)) ||
        agentId is! String ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(agentId) ||
        source.origin != EpisodeSourceOrigin.user ||
        due == null ||
        expiry == null ||
        !expiry.isAfter(due) ||
        expiry.difference(due) > const Duration(days: 1) ||
        status == null) {
      throw const FormatException('invalid followup fields');
    }
    return ProactiveConversationTopic(
      id: id,
      label: label,
      source: source,
      agentId: agentId,
      ownerKey: ownerKey,
      dueAt: due,
      expiresAt: expiry,
      status: status,
    );
  }
}

/// Narrow explicit times only. Ambiguous event timing cannot authorize a send.
ProactiveConversationTopic? parseDirectFollowup(
  String text,
  EpisodeSourceRef source,
  DateTime now, {
  String agentId = 'self',
  String? ownerKey,
}) {
  final normalized = text.trim();
  final chinese = RegExp(
    r'^(今天|明天|后天)(\d{1,2})(?:点|:|：)(?:(\d{1,2})(?:分)?)?[，, ]*(?:问问我|问我|跟我聊聊|聊聊)([^。！？!?\n<>`]{2,40})[。.!！]?$',
  ).firstMatch(normalized);
  final english = RegExp(
    r'^(today|tomorrow|the day after tomorrow) at (\d{1,2}):(\d{2}),? (?:ask me about|check in about) ([a-zA-Z0-9][a-zA-Z0-9 -]{1,39})[.!]?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  final match = chinese ?? english;
  if (match == null) return null;
  final hour = int.parse(match.group(2)!);
  final minute = int.tryParse(match.group(3) ?? '0') ?? 0;
  if (hour > 23 || minute > 59) return null;
  final label = match.group(4)!.trim();
  final offset = {
    '今天': 0,
    '明天': 1,
    '后天': 2,
    'today': 0,
    'tomorrow': 1,
    'the day after tomorrow': 2,
  }[match.group(1)!.toLowerCase()]!;
  final due = now.isUtc
      ? DateTime.utc(now.year, now.month, now.day + offset, hour, minute)
      : DateTime(now.year, now.month, now.day + offset, hour, minute);
  if (!due.isAfter(now)) return null;
  final id = sha256
      .convert(
        utf8.encode(
          '${source.sourceId}:${source.contentHash}:$label:${due.toUtc().toIso8601String()}',
        ),
      )
      .toString()
      .substring(0, 32);
  return ProactiveConversationTopic(
    id: id,
    label: label,
    source: source,
    agentId: agentId,
    ownerKey: ownerKey,
    dueAt: due,
    expiresAt: due.add(const Duration(hours: 12)),
  );
}
