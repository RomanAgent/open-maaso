import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

import 'offline_skill.dart';
import 'offline_store.dart';

export 'offline_skill.dart';

/// A local prompt library. Editing a skill never executes code or calls a model.
class OfflineSkillsPage extends StatefulWidget {
  const OfflineSkillsPage({super.key, required this.store, this.onChanged});
  final OfflineStore store;
  final VoidCallback? onChanged;

  @override
  State<OfflineSkillsPage> createState() => _OfflineSkillsPageState();
}

class _OfflineSkillsPageState extends State<OfflineSkillsPage> {
  List<OfflineSkill> _skills = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _readGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant OfflineSkillsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.store, oldWidget.store)) unawaited(_reload());
  }

  Future<void> _reload() async {
    final generation = ++_readGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final values = await widget.store.listSkills();
      if (mounted && generation == _readGeneration) {
        setState(() {
          _skills = values;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _readGeneration) {
        setState(() {
          _error = '读取本地技能失败，请重试。';
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggle(OfflineSkill skill, bool enabled) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.saveSkill(skill.copyWith(enabled: enabled));
      if (mounted) {
        widget.onChanged?.call();
        await _reload();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '修改未保存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([OfflineSkill? skill]) async {
    if (_saving || _loading) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _OfflineSkillEditor(store: widget.store, skill: skill),
    );
    if (saved == true && mounted) {
      widget.onChanged?.call();
      await _reload();
    }
  }

  Future<void> _delete(OfflineSkill skill) async {
    if (_saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地技能？'),
        content: Text('删除“${skill.name}”后，将不再应用这条提示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.deleteSkill(skill.id);
      if (mounted) {
        widget.onChanged?.call();
        await _reload();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '删除未完成，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final secondary = dark
        ? MaasoFrostTokens.darkTextSecondary
        : MaasoFrostTokens.lightTextSecondary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地技能'),
        actions: [
          IconButton(
            tooltip: '刷新技能',
            onPressed: _saving ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '添加技能',
            onPressed:
                _saving || _loading || _skills.length >= OfflineSkill.maxCount
                ? null
                : _edit,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        '把常用偏好保存在本机，启用后用于下一次模型对话。',
                        style: TextStyle(color: secondary),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_skills.length}/${OfflineSkill.maxCount} 条 · ${_skills.where((s) => s.enabled).length} 条已启用',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 16),
                      if (_error != null) ...[
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                          key: const Key('local-skill-error'),
                        ),
                        TextButton(onPressed: _reload, child: const Text('重试')),
                        const SizedBox(height: 12),
                      ],
                      if (_skills.isEmpty && _error == null) ...[
                        const SizedBox(height: 32),
                        const Icon(Icons.extension_outlined, size: 40),
                        const SizedBox(height: 12),
                        const Text('还没有本地技能', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        Center(
                          child: FilledButton.icon(
                            onPressed: _edit,
                            icon: const Icon(Icons.add),
                            label: const Text('添加技能'),
                          ),
                        ),
                      ],
                      for (final skill in _skills)
                        Card(
                          key: ValueKey('local-skill-${skill.id}'),
                          margin: const EdgeInsets.only(bottom: 12),
                          color: dark
                              ? MaasoFrostTokens.darkMuted
                              : MaasoFrostTokens.lightMuted,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              MaasoFrostTokens.cardRadius,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        skill.name,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Semantics(
                                      label: '启用${skill.name}',
                                      child: Switch(
                                        value: skill.enabled,
                                        onChanged: _saving
                                            ? null
                                            : (enabled) =>
                                                  _toggle(skill, enabled),
                                      ),
                                    ),
                                  ],
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text(
                                    skill.instructions,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: secondary),
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton.icon(
                                      onPressed: _saving
                                          ? null
                                          : () => _edit(skill),
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('编辑'),
                                    ),
                                    IconButton(
                                      tooltip: '删除${skill.name}',
                                      onPressed: _saving
                                          ? null
                                          : () => _delete(skill),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        '每条提示最多 8,192 个字符，仅影响回答方式，不执行脚本。技能随设置中的本地备份一并导入和导出。',
                        style: TextStyle(color: secondary),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _OfflineSkillEditor extends StatefulWidget {
  const _OfflineSkillEditor({required this.store, this.skill});
  final OfflineStore store;
  final OfflineSkill? skill;
  @override
  State<_OfflineSkillEditor> createState() => _OfflineSkillEditorState();
}

class _OfflineSkillEditorState extends State<_OfflineSkillEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _instructions;
  late final String _id;
  late bool _enabled;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _id = widget.skill?.id ?? const Uuid().v4();
    _name = TextEditingController(text: widget.skill?.name ?? '');
    _instructions = TextEditingController(
      text: widget.skill?.instructions ?? '',
    );
    _enabled = widget.skill?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = OfflineSkill.fromJson({
        'id': _id,
        'name': _name.text,
        'instructions': _instructions.text,
        'enabled': _enabled,
      });
      await widget.store.saveSkill(value);
      if (mounted) Navigator.pop(context, true);
    } on FormatException {
      if (mounted) setState(() => _error = '请检查名称、提示长度及不可见控制字符。');
    } catch (_) {
      if (mounted) setState(() => _error = '未能保存到本机，已保留你的输入，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.skill == null ? '添加本地技能' : '编辑本地技能'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                enabled: !_saving,
                maxLength: OfflineSkill.maxNameLength,
                decoration: const InputDecoration(labelText: '技能名称'),
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入技能名称' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _instructions,
                enabled: !_saving,
                minLines: 5,
                maxLines: 10,
                maxLength: OfflineSkill.maxInstructionLength,
                decoration: const InputDecoration(
                  labelText: '提示内容',
                  alignLabelWithHint: true,
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入提示内容' : null,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用这条技能'),
                value: _enabled,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _enabled = value),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存到本机'),
        ),
      ],
    ),
  );
}
