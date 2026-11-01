import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';

import '../data/people_safety_client.dart';
import 'ai_output_report_dialog.dart';

bool isReportableHomeAIReply(ChatMessage message) =>
    message.id != null &&
    message.sessionId == 'self' &&
    !message.isUserMessage &&
    message.senderId != 'user' &&
    message.content.trim().isNotEmpty;

Future<void> reportHomeAIReply(
  BuildContext context,
  ChatMessage message,
) async {
  final gateway = appServices.maybeFind<PeopleSafetyClient>();
  final database = appServices.maybeFind<DBService>();
  if (!isReportableHomeAIReply(message) ||
      gateway == null ||
      !gateway.active ||
      database == null) {
    return;
  }
  final key = gateway.contextKey;
  final uiControl = appServices.maybeFind<AgentUiControlService>();
  uiControl?.coordinator.pauseForUserActivity(reason: 'ai_report_preview');
  final id = message.id;
  final text = message.content;
  final timestamp = message.timestamp;
  final sender = message.senderId;
  // A Home widget may briefly retain the previous account's rows while its
  // asynchronous history reload is pending. Re-check the current owned store.
  final List<ChatMessage> current;
  try {
    current = await database.getRecentMessages('self', limit: 120);
  } catch (_) {
    return;
  }
  if (!context.mounted ||
      !gateway.active ||
      gateway.contextKey != key ||
      !identical(appServices.maybeFind<PeopleSafetyClient>(), gateway) ||
      !identical(appServices.maybeFind<DBService>(), database) ||
      !current.any(
        (row) =>
            isReportableHomeAIReply(row) &&
            row.id == id &&
            row.content == text &&
            row.timestamp == timestamp &&
            row.senderId == sender,
      )) {
    return;
  }
  await showAIOutputReportDialog(
    context: context,
    gateway: gateway,
    selectedText: text,
    onUserActivity: () =>
        uiControl?.coordinator.pauseForUserActivity(reason: 'ai_report_input'),
  );
}
