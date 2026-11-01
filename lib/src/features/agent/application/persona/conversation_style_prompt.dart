import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';

/// Shared expression rules; never changes a chat path's output protocol.
abstract final class ConversationStylePrompt {
  static String render(
    ConversationStyleSnapshot snapshot, {
    required AppLocale locale,
    bool compact = false,
  }) {
    String prompt(String suffix, {Map<String, Object?> params = const {}}) =>
        AgentPromptCatalog.text(
          'runtime.conversation_style.$suffix',
          locale: locale,
          params: params,
        );
    String detail(String suffix, {Map<String, Object?> params = const {}}) =>
        prompt(compact ? 'compact.$suffix' : suffix, params: params);

    final parts = <String>[prompt(compact ? 'core_compact' : 'core').trim()];
    // Public Agents must not receive the private companion's relationship,
    // preferences or boundaries even when a caller passes a populated DTO.
    if (!snapshot.isPrivate) {
      parts.add(detail('public').trim());
      return parts.join('\n\n');
    }

    parts.add(detail('private').trim());
    parts.add(detail('contact_contract').trim());
    parts.add(detail('phase.${snapshot.expressionStage.key}').trim());
    if (snapshot.noTeasing) parts.add(detail('boundary.no_teasing').trim());
    if (snapshot.noUnsolicitedAdvice) {
      parts.add(detail('boundary.no_unsolicited_advice').trim());
    }
    if (snapshot.serious) parts.add(detail('boundary.serious').trim());
    if (snapshot.repairRequired) parts.add(detail('boundary.repair').trim());
    if (snapshot.neutralAddressOnly) {
      parts.add(detail('boundary.neutral_address').trim());
    }
    if (snapshot.contactGuidance != null) {
      parts.add(snapshot.contactGuidance!);
    }
    final policyData = <String, Object?>{
      if (snapshot.preferredAddress != null)
        'preferredAddress': snapshot.preferredAddress,
      if (snapshot.banterBoundaries.isNotEmpty)
        'banter': {
          for (final entry in snapshot.banterBoundaries.entries)
            entry.key: entry.value.name,
        },
      if (snapshot.sharedContexts.isNotEmpty)
        'sharedContexts': [
          for (final fact in snapshot.sharedContexts)
            {'label': fact.draft.label, 'kind': fact.draft.evidenceKind?.name},
        ],
    };
    if (policyData.isNotEmpty) {
      final data = jsonEncode(policyData)
          .replaceAll('<', r'\u003c')
          .replaceAll('>', r'\u003e')
          .replaceAll('&', r'\u0026')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
      parts.add(detail('policy_data', params: {'data': data}).trim());
    }
    // The immutable snapshot owns address validation and size limits. Do not
    // apply a second, smaller budget that could silently drop a user boundary.
    final addresses = snapshot.forbiddenAddresses;
    if (addresses.isNotEmpty) {
      final data = jsonEncode({'forbiddenAddresses': addresses})
          .replaceAll('<', r'\u003c')
          .replaceAll('>', r'\u003e')
          .replaceAll('&', r'\u0026')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
      parts.add(detail('boundary.addresses', params: {'data': data}).trim());
    }
    return parts.join('\n\n');
  }
}
