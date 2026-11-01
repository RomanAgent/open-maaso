import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Factory helpers + string-typed registry for agent-pushed cards.
///
/// Two callers:
///   * **Dart** — boot/onboarding controllers use the typed factories
///     (e.g. [confirmName]) for direct, type-safe pushes.
///   * **Agent (JS via tool-call)** — `ShowCardSkill` parses a
///     `{type, props}` JSON envelope and dispatches through [fromType].
///
/// To add a new card type:
///   1. Write a private factory `_buildXxx(Map props)` below that returns
///      an [AgentCard].
///   2. Wire its `'xxx'` discriminator into [_registry].
///   3. Document the structured schema in [ShowCardSkill.nativeToolSchemas].
class AgentCards {
  AgentCards._();

  // ───────────────────────── public factories ─────────────────────────

  static AgentCard confirmName({
    required String candidate,
    required VoidCallback onConfirm,
    required VoidCallback onBack,
  }) {
    final controller = appServices.find<AgentCardController>();
    return AgentCard(
      type: 'confirm_name',
      title: 'card.confirm_name_title',
      props: {'candidate': candidate},
      builder: (ctx) => _ConfirmNameBody(candidate: candidate),
      actions: AgentCardActions(
        backLabel: 'card.confirm_name_back',
        onBack: () {
          controller.dismissCurrent();
          onBack();
        },
        nextLabel: 'card.confirm_name_next',
        onNext: () {
          controller.dismissCurrent();
          onConfirm();
        },
      ),
    );
  }

  // ───────────────────── agent-driven registry ─────────────────────

  /// Resolve a typed card from a JSON envelope.  Returns null when [type]
  /// is unknown so the skill can return a structured error to the JS
  /// caller instead of silently swallowing it.
  static AgentCard? fromType(String type, Map<String, dynamic> props) {
    final builder = _registry[type];
    if (builder == null) return null;
    return builder(props);
  }

  static final Map<String, AgentCard Function(Map<String, dynamic>)> _registry =
      {'set_api_key': _buildSetApiKey, 'debug_stats': _buildDebugStats};

  static AgentCard _buildSetApiKey(Map<String, dynamic> props) {
    final controller = appServices.find<AgentCardController>();
    final llm = appServices.maybeFind<LLMConfigController>();
    final llmSession = llm?.requireActiveAccountSession();
    final keyCtrl = TextEditingController(
      text: (props['prefilled_key'] as String?)?.trim() ?? '',
    );
    final baseUrlCtrl = TextEditingController(
      text: (props['base_url'] as String?)?.trim().isNotEmpty == true
          ? props['base_url'] as String
          : LLMDefaults.baseUrl,
    );
    final modelCtrl = TextEditingController(
      text: (props['model'] as String?)?.trim().isNotEmpty == true
          ? props['model'] as String
          : LLMDefaults.model,
    );
    final cardId = 'set_api_key_${DateTime.now().microsecondsSinceEpoch}';
    return AgentCard(
      id: cardId,
      type: 'set_api_key',
      title: 'card.api_key_title',
      props: props,
      builder: (ctx) => _SetApiKeyBody(
        keyCtrl: keyCtrl,
        baseUrlCtrl: baseUrlCtrl,
        modelCtrl: modelCtrl,
      ),
      actions: AgentCardActions(
        backLabel: 'common.cancel',
        onBack: () => controller.dismissById(cardId),
        nextLabel: 'common.save',
        onNext: () async {
          final key = keyCtrl.text.trim();
          if (key.isEmpty) {
            showAppGlassNotice(
              title: 'settings.api_key'.tr,
              message: 'card.api_key_empty'.tr,
              icon: Icons.vpn_key_off_rounded,
            );
            return;
          }
          if (llm != null && llmSession != null) {
            await llm.saveConfig(
              key,
              baseUrlCtrl.text.trim().isEmpty
                  ? LLMDefaults.baseUrl
                  : baseUrlCtrl.text.trim(),
              modelCtrl.text.trim().isEmpty
                  ? LLMDefaults.model
                  : modelCtrl.text.trim(),
              session: llmSession,
              enabled: true,
            );
          }
          controller.dismissById(cardId);
          showAppGlassNotice(
            title: 'settings.api_key'.tr,
            message: 'card.api_key_saved'.tr,
            icon: Icons.check_circle_outline_rounded,
          );
        },
      ),
    );
  }

  static AgentCard _buildDebugStats(Map<String, dynamic> props) {
    final controller = appServices.find<AgentCardController>();
    final cardId = 'debug_stats_${DateTime.now().microsecondsSinceEpoch}';
    return AgentCard(
      id: cardId,
      type: 'debug_stats',
      title: null,
      props: props,
      builder: (ctx) => _DebugStatsBody(
        props: props,
        onClose: () => controller.dismissById(cardId),
      ),
    );
  }
}

// ─────────────────────── confirm_name body ───────────────────────

class _ConfirmNameBody extends StatelessWidget {
  final String candidate;
  const _ConfirmNameBody({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'card.confirm_name_body_prefix'.tr,
          style: TextStyle(fontSize: 14, color: glass.foregroundSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          candidate,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: glass.foregroundPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'card.confirm_name_body_suffix'.tr,
          style: TextStyle(fontSize: 14, color: glass.foregroundSecondary),
        ),
      ],
    );
  }
}

// ─────────────────────── set_api_key body ───────────────────────

class _SetApiKeyBody extends StatefulWidget {
  final TextEditingController keyCtrl;
  final TextEditingController baseUrlCtrl;
  final TextEditingController modelCtrl;

  const _SetApiKeyBody({
    required this.keyCtrl,
    required this.baseUrlCtrl,
    required this.modelCtrl,
  });

  @override
  State<_SetApiKeyBody> createState() => _SetApiKeyBodyState();
}

class _SetApiKeyBodyState extends State<_SetApiKeyBody> {
  bool _obscure = true;
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'card.api_key_description'.tr,
          style: TextStyle(
            fontSize: 13,
            color: glass.foregroundSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        AppGlassField(
          controller: widget.keyCtrl,
          obscureText: _obscure,
          labelText: 'settings.api_key'.tr,
          hintText: 'settings.api_key_hint'.tr,
          suffix: IconButton(
            icon: Icon(
              _obscure
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
            ),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: () => setState(() => _advanced = !_advanced),
          child: Row(
            children: [
              Icon(
                _advanced
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 18,
                color: glass.foregroundSecondary,
              ),
              Text(
                'card.advanced'.tr,
                style: TextStyle(
                  fontSize: 12,
                  color: glass.foregroundSecondary,
                ),
              ),
            ],
          ),
        ),
        if (_advanced) ...[
          const SizedBox(height: 8),
          AppGlassField(
            controller: widget.baseUrlCtrl,
            labelText: 'settings.base_url'.tr,
          ),
          const SizedBox(height: 8),
          AppGlassField(
            controller: widget.modelCtrl,
            labelText: 'settings.model'.tr,
          ),
        ],
      ],
    );
  }
}

// ─────────────────────── debug_stats body ───────────────────────

class _DebugStatsBody extends StatelessWidget {
  final Map<String, dynamic> props;
  final VoidCallback onClose;

  const _DebugStatsBody({required this.props, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final modelRows = _rowMaps(props['model_rows']).toList();
    final storageRows = _rowMaps(props['storage_rows']).toList();
    final runtimeRows = _rowMaps(props['runtime_rows']).toList();
    final legacyRows = _rowMaps(props['rows']).toList();
    final rawWave = props['intent_wave'];
    final intentWave = rawWave is Map
        ? Map<String, dynamic>.from(rawWave)
        : const <String, dynamic>{};
    final rawWaveRows = intentWave['rows'];
    final waveRows = rawWaveRows is List
        ? rawWaveRows.whereType<Map>().map((r) => Map<String, dynamic>.from(r))
        : const Iterable<Map<String, dynamic>>.empty();
    final rawEvidence = intentWave['evidence'];
    final evidence = rawEvidence is List
        ? rawEvidence.map((e) => e.toString()).toList()
        : const <String>[];
    final rawEntangled = props['entangled_memory'];
    final entangledMemory = rawEntangled is Map
        ? Map<String, dynamic>.from(rawEntangled)
        : const <String, dynamic>{};
    final rawRecentEdges = entangledMemory['recent'];
    final recentEdges = rawRecentEdges is List
        ? rawRecentEdges.whereType<Map>().map(
            (r) => Map<String, dynamic>.from(r),
          )
        : const Iterable<Map<String, dynamic>>.empty();
    final rawDelayed = props['delayed_choice'];
    final delayedChoice = rawDelayed is Map
        ? Map<String, dynamic>.from(rawDelayed)
        : const <String, dynamic>{};
    final rawPending = delayedChoice['pending'];
    final pendingBranches = rawPending is List
        ? rawPending.whereType<Map>().map((r) => Map<String, dynamic>.from(r))
        : const Iterable<Map<String, dynamic>>.empty();
    final rawDcEvents = delayedChoice['events'];
    final dcEvents = rawDcEvents is List
        ? rawDcEvents.whereType<Map>().map((r) => Map<String, dynamic>.from(r))
        : const Iterable<Map<String, dynamic>>.empty();
    final note = props['note']?.toString() ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'card.debug_stats'.tr,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: glass.foregroundPrimary,
                ),
              ),
            ),
            Tooltip(
              message: 'common.close'.tr,
              child: IconButton(
                onPressed: onClose,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: glass.foregroundSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (modelRows.isNotEmpty) ...[
          _DebugSection(
            icon: Icons.memory_rounded,
            title: 'card.debug_models'.tr,
            rows: modelRows,
          ),
          const SizedBox(height: 12),
        ],
        if (storageRows.isNotEmpty) ...[
          _DebugSection(
            icon: Icons.storage_rounded,
            title: 'card.debug_storage'.tr,
            rows: storageRows,
          ),
          const SizedBox(height: 12),
        ],
        if (runtimeRows.isNotEmpty) ...[
          _DebugSection(
            icon: Icons.monitor_heart_rounded,
            title: 'card.debug_runtime'.tr,
            rows: runtimeRows,
          ),
          const SizedBox(height: 12),
        ],
        if (modelRows.isEmpty && storageRows.isEmpty && runtimeRows.isEmpty)
          for (final row in legacyRows) ...[
            _DebugStatRow(
              label: row['label']?.toString() ?? '',
              value: row['value']?.toString() ?? '',
              detail: row['detail']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
          ],
        if (intentWave.isNotEmpty ||
            entangledMemory.isNotEmpty ||
            delayedChoice.isNotEmpty) ...[
          _DebugSectionHeader(
            icon: Icons.account_tree_rounded,
            title: 'card.debug_signals'.tr,
          ),
          const SizedBox(height: 8),
        ],
        if (intentWave.isNotEmpty) ...[
          Text(
            'card.debug_intent_wave'.trParams({
              'dominant': (intentWave['dominant'] ?? '-').toString(),
              'entropy': (intentWave['entropy'] ?? '-').toString(),
            }),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: glass.foregroundPrimary,
            ),
          ),
          const SizedBox(height: 8),
          _DebugStatRow(
            label: 'card.debug_last_collapse'.tr,
            value: intentWave['lastCollapsed']?.toString() ?? '-',
            detail: intentWave['lastReason']?.toString() ?? '',
          ),
          const SizedBox(height: 10),
          for (final row in waveRows.take(4)) ...[
            _DebugStatRow(
              label: row['label']?.toString() ?? '',
              value: row['value']?.toString() ?? '',
              detail: row['detail']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
          ],
          if (evidence.isNotEmpty)
            Text(
              evidence.join('\n'),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: glass.foregroundSecondary,
              ),
            ),
          const SizedBox(height: 10),
        ],
        if (entangledMemory.isNotEmpty) ...[
          Text(
            'card.debug_entangled_memory'.trParams({
              'count': (entangledMemory['edgeCount'] ?? 0).toString(),
            }),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: glass.foregroundPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final edge in recentEdges) ...[
            _DebugStatRow(
              label: edge['relation']?.toString() ?? '',
              value: edge['weight']?.toString() ?? '',
              detail: edge['evidence']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (delayedChoice.isNotEmpty) ...[
          Text(
            'card.debug_delayed_choice'.trParams({
              'count': (delayedChoice['pendingCount'] ?? 0).toString(),
            }),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: glass.foregroundPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final branch in pendingBranches.take(3)) ...[
            _DebugStatRow(
              label: branch['tool']?.toString() ?? '',
              value: branch['risk']?.toString() ?? '',
              detail: branch['summary']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
          ],
          for (final event in dcEvents.take(3)) ...[
            _DebugStatRow(
              label: event['kind']?.toString() ?? '',
              value: '',
              detail: event['detail']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (note.isNotEmpty)
          Text(
            note,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: glass.foregroundSecondary,
            ),
          ),
      ],
    );
  }

  Iterable<Map<String, dynamic>> _rowMaps(Object? raw) {
    if (raw is! List) return const Iterable<Map<String, dynamic>>.empty();
    return raw.whereType<Map>().map((r) => Map<String, dynamic>.from(r));
  }
}

class _DebugSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Map<String, dynamic>> rows;

  const _DebugSection({
    required this.icon,
    required this.title,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DebugSectionHeader(icon: icon, title: title),
        const SizedBox(height: 8),
        for (final row in rows) ...[
          _DebugStatRow(
            label: row['label']?.toString() ?? '',
            value: row['value']?.toString() ?? '',
            detail: row['detail']?.toString() ?? '',
          ),
          if (row != rows.last) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _DebugSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const _DebugSectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 15, color: glass.foregroundSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: glass.foregroundSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _DebugStatRow extends StatelessWidget {
  final String label;
  final String value;
  final String detail;

  const _DebugStatRow({
    required this.label,
    required this.value,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: glass.muted,
        borderRadius: BorderRadius.circular(MaasoGlassTheme.fieldRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: glass.foregroundPrimary,
                  ),
                ),
              ],
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  color: glass.foregroundSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
