import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_notice_surface.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import '../application/account_deletion_service.dart';
import '../application/account_deletion_page_adapter.dart';

class AccountDeletionRoutePage extends StatelessWidget {
  const AccountDeletionRoutePage({super.key, this.route = '/account-deletion'});
  final String route;
  @override
  Widget build(BuildContext context) {
    final service = appServices.maybeFind<AccountDeletionService>();
    if (service == null) {
      return AppSecondaryScaffold(
        header: AppSecondaryHeader(
          title: Localizations.localeOf(context).languageCode == 'zh'
              ? '删除 Maaso 账号'
              : 'Delete Maaso account',
          onBack: () => appNavigation.pop(),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                Localizations.localeOf(context).languageCode == 'zh'
                    ? '账号删除服务暂不可用。已保存的回执仍然保留，请稍后刷新状态。'
                    : 'Account deletion is temporarily unavailable. Saved receipts remain available; refresh status later.',
              ),
            ],
          ),
        ),
      );
    }
    return AccountDeletionPage(service: service, route: route);
  }
}

class AccountDeletionPage extends StatefulWidget {
  const AccountDeletionPage({
    super.key,
    required this.service,
    this.route = '/account-deletion',
    this.uiControl,
    this.openExternal,
  });
  final AccountDeletionService service;
  final String route;
  final AgentUiControlService? uiControl;
  final Future<bool> Function(Uri uri)? openExternal;
  @override
  State<AccountDeletionPage> createState() => _AccountDeletionPageState();
}

class _AccountDeletionPageState extends State<AccountDeletionPage> {
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _code = TextEditingController();
  String? _observedContext;
  bool _erase = false, _billing = false, _sendingCode = false;
  int? _codeId;
  String? _codeMessage;
  AgentUiControlService? _ui;
  AccountDeletionPageAdapter? _adapter;
  PageAgentAdapterRegistration<AccountDeletionPageAdapter>? _registration;
  bool get zh => Localizations.localeOf(context).languageCode == 'zh';
  String t(String en, String cn) => zh ? cn : en;
  @override
  void initState() {
    super.initState();
    _observedContext = widget.service.contextKey;
    widget.service.addListener(_contextUpdate);
    _ui = widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    if (_ui != null) {
      _adapter = AccountDeletionPageAdapter(
        route: widget.route,
        service: widget.service,
        coordinator: _ui!.coordinator,
      );
      _registration = _ui!.adapters.register(_adapter!);
    }
    unawaited(widget.service.refresh());
  }

  void _contextUpdate() {
    if (_observedContext == widget.service.contextKey) return;
    _observedContext = widget.service.contextKey;
    _email.clear();
    _password.clear();
    _code.clear();
    _codeId = null;
    _erase = false;
    _billing = false;
    _codeMessage = null;
  }

  void takeover() => _ui?.coordinator.pauseForUserActivity(
    reason: 'account_deletion_user_control',
  );
  @override
  void dispose() {
    widget.service.removeListener(_contextUpdate);
    _adapter?.detach();
    _registration?.unregister();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    takeover();
    final ok =
        await (widget.openExternal?.call(uri) ??
            launchUrl(uri, mode: LaunchMode.externalApplication));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        appGlassSnackBar(
          content: Text(
            t('Could not open subscription management.', '暂时无法打开订阅管理。'),
          ),
        ),
      );
    }
  }

  Future<void> _verify() async {
    takeover();
    setState(() {
      _erase = false;
      _billing = false;
    });
    final pass = _password.text;
    _password.clear();
    await widget.service.verify(
      email: _email.text,
      password: pass,
      codeId: _codeId,
      code: _code.text,
    );
    _code.clear();
  }

  Future<void> _requestCode() async {
    takeover();
    if (_sendingCode) return;
    final contextKey = widget.service.contextKey;
    setState(() {
      _sendingCode = true;
      _codeMessage = null;
    });
    try {
      final id = await widget.service.requestEmailCode!(_email.text.trim());
      if (mounted && contextKey == widget.service.contextKey) {
        setState(() {
          _codeId = id;
          _codeMessage = t('Verification code sent.', '验证码已发送。');
        });
      }
    } catch (_) {
      if (mounted && contextKey == widget.service.contextKey) {
        setState(
          () => _codeMessage = t(
            'Could not send a verification code.',
            '验证码发送失败。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _confirm() async {
    takeover();
    if (!_erase || !_billing) return;
    final contextKey = widget.service.contextKey;
    final decision = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Permanently delete Maaso?', '永久删除 Maaso 账号？')),
        content: Text(
          t(
            'Your Maaso access stops immediately, including use of remaining coins and membership benefits. Deletion does not automatically refund purchases. Processing follows the deadline shown in this review. Subscriptions may continue charging separately.',
            'Maaso 访问权限将立即停止，剩余币和会员权益将无法继续使用。删除不会自动退款，数据按当前页面显示的时限处理，商店订阅可能继续单独扣费。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('Keep account', '保留账号')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('Confirm deletion', '确认删除')),
          ),
        ],
      ),
    );
    if (decision == true &&
        mounted &&
        contextKey == widget.service.contextKey) {
      await widget.service.confirmByUser(
        eraseAcknowledged: _erase,
        billingAcknowledged: _billing,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final s = widget.service,
          p = s.preview,
          status = s.status,
          colors = Theme.of(context).colorScheme;
      return AppSecondaryScaffold(
        header: AppSecondaryHeader(
          title: t('Delete Maaso account', '删除 Maaso 账号'),
          onBack: () => appNavigation.pop(),
        ),
        body: SafeArea(
          child: Listener(
            onPointerDown: (_) => takeover(),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      t(
                        'Delete your Maaso profile, Agent and content',
                        '删除你的 Maaso 身份、Agent 和内容',
                      ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t(
                        'After confirmation, remaining coins and membership benefits become inaccessible. Deletion does not automatically issue a refund. Shared device settings and unscoped API keys are retained; remove them separately in settings if needed.',
                        '确认后，剩余币和会员权益将无法继续使用，删除不会自动退款。设备共享设置和未按账号存储的 API 密钥会保留，如需移除，请另行在设置中处理。',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t(
                        'This removes your Maaso data. Other products using this shared login remain available. Necessary private payment and refund records remain linked only to a retired account identifier.',
                        '此操作删除 Maaso 数据；使用同一登录身份的其他产品仍保留。必要的私有支付与退款记录继续绑定已注销的账号标识。',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t(
                        'Deleting Maaso does not cancel Apple or Google subscriptions. You can request deletion without waiting for them to expire.',
                        '删除账号不会取消 Apple 或 Google 订阅，也无需等订阅到期才能删除。',
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => _open(
                            Uri.parse(
                              'https://apps.apple.com/account/subscriptions',
                            ),
                          ),
                          child: Text(t('Apple subscriptions', 'Apple 订阅')),
                        ),
                        TextButton(
                          onPressed: () => _open(
                            Uri.parse(
                              'https://play.google.com/store/account/subscriptions',
                            ),
                          ),
                          child: Text(
                            t('Google Play subscriptions', 'Google Play 订阅'),
                          ),
                        ),
                      ],
                    ),
                    if (s.errorCode != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error(s.errorCode!),
                          key: const Key('deletion-error'),
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (s.busy) const LinearProgressIndicator(),
                    if (status != null) ...[
                      const Divider(),
                      Text(
                        status.completed
                            ? t('Deletion completed', '删除已完成')
                            : t('Deletion request received', '已收到删除请求'),
                        key: const Key('deletion-status'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        t(
                          'Receipt: ${status.requestId}',
                          '回执：${status.requestId}',
                        ),
                      ),
                      if (status.dueAt != null)
                        Text(
                          t(
                            'Processing deadline: ${status.dueAt!.toLocal()}',
                            '处理截止时间：${status.dueAt!.toLocal()}',
                          ),
                        ),
                      if (status.completedAt != null)
                        Text(
                          t(
                            'Completed: ${status.completedAt!.toLocal()}',
                            '完成时间：${status.completedAt!.toLocal()}',
                          ),
                        ),
                      if (status.needsOperatorAttention)
                        Text(
                          t(
                            'The operator needs to finish or retry processing. The request is not complete yet.',
                            '运营人员仍需处理或重试，当前尚未完成删除。',
                          ),
                        ),
                      if (s.localCleanupPending)
                        FilledButton.tonal(
                          onPressed: s.busy ? null : s.finishLocalCleanupByUser,
                          child: Text(
                            t('Finish local sign-out and cleanup', '完成本机退出和清理'),
                          ),
                        ),
                    ],
                    if (status == null && !s.ready && !s.busy)
                      Text(
                        t(
                          'Account deletion is temporarily unavailable. Saved receipts remain available; refresh status later.',
                          '账号删除服务暂不可用。已保存的回执仍然保留，请稍后刷新状态。',
                        ),
                      ),
                    if (status == null && s.ready && s.signedIn) ...[
                      const Divider(),
                      TextField(
                        controller: _email,
                        onChanged: (_) => takeover(),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: InputDecoration(
                          labelText: t('Account email', '账号邮箱'),
                        ),
                      ),
                      if (_codeId == null)
                        TextField(
                          controller: _password,
                          onChanged: (_) => takeover(),
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: t('Current password', '当前密码'),
                          ),
                        ),
                      if (widget.service.requestEmailCode != null)
                        TextButton(
                          onPressed: s.busy || _sendingCode
                              ? null
                              : _requestCode,
                          child: Text(
                            t('Use email verification code', '使用邮箱验证码'),
                          ),
                        ),
                      if (_codeId != null)
                        TextField(
                          controller: _code,
                          onChanged: (_) => takeover(),
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('Email verification code', '邮箱验证码'),
                          ),
                        ),
                      if (_codeMessage != null) Text(_codeMessage!),
                      FilledButton.tonal(
                        onPressed: s.busy ? null : _verify,
                        child: Text(
                          t('Verify and review deletion', '验证并查看删除详情'),
                        ),
                      ),
                    ],
                    if (p != null) ...[
                      const Divider(),
                      Text(
                        t(
                          'Deletion within ${p.slaDays} days after confirmation',
                          '确认后 ${p.slaDays} 天内处理删除',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(p.maintenanceNotice),
                      for (final sub in p.subscriptions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${sub.provider} · ${sub.tier}'),
                          subtitle: Text(
                            sub.autoRenew
                                ? t('Auto-renewal is enabled', '自动续费已开启')
                                : t(
                                    'Review the subscription in your store',
                                    '请在商店确认订阅状态',
                                  ),
                          ),
                          trailing: TextButton(
                            onPressed: () => _open(sub.manageUri),
                            child: Text(t('Manage', '管理')),
                          ),
                        ),
                      Text(
                        p.retainsOtherProducts
                            ? t(
                                'Other product credentials will be retained.',
                                '将保留其他产品需要的登录凭据。',
                              )
                            : t(
                                'Shared login personal data is removed if no other product is active when deletion executes.',
                                '执行删除时，如无其他活跃产品，将一并清理共用登录的个人资料。',
                              ),
                      ),
                      CheckboxListTile(
                        value: _erase,
                        onChanged: s.busy
                            ? null
                            : (v) => setState(() => _erase = v == true),
                        title: Text(
                          t(
                            'I understand Maaso data will be permanently erased.',
                            '我理解 Maaso 数据将被永久删除。',
                          ),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      CheckboxListTile(
                        value: _billing,
                        onChanged: s.busy
                            ? null
                            : (v) => setState(() => _billing = v == true),
                        title: Text(
                          t(
                            'I understand subscriptions may continue charging separately.',
                            '我理解商店订阅可能继续单独扣费。',
                          ),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      FilledButton(
                        key: const Key('deletion-confirm'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.error,
                          foregroundColor: colors.onError,
                        ),
                        onPressed: s.busy || !_erase || !_billing
                            ? null
                            : _confirm,
                        child: Text(
                          t(
                            'Permanently delete Maaso account',
                            '永久删除 Maaso 账号',
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: s.busy ? null : s.refresh,
                      child: Text(t('Refresh status', '刷新状态')),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  String _error(String code) => switch (code) {
    'context_changed' || 'receipt_environment_mismatch' => t(
      'The account or environment changed. Reopen deletion from the original account.',
      '账号或环境已切换，请从原账号重新打开删除页面。',
    ),
    'DELETION_VERIFICATION_REQUIRED' || 'verification_failed' => t(
      'Account verification failed. Check the credentials and try again.',
      '账号验证失败，请检查验证信息后重试。',
    ),
    'request_uncertain' => t(
      'The request outcome is uncertain. Refresh the saved receipt before retrying.',
      '暂时无法确认请求结果，请先刷新已保存的回执。',
    ),
    'local_cleanup_pending' => t(
      'The server accepted deletion. Finish local cleanup when the account runtime has stopped.',
      '服务器已接受删除，请在账号运行停止后完成本机清理。',
    ),
    'receipt_storage_failed' => t(
      'Could not save a private receipt. Deletion was not sent.',
      '私有回执保存失败，尚未发送删除请求。',
    ),
    _ => t(
      'The deletion service is unavailable. Existing receipts remain saved.',
      '删除服务暂不可用，已有回执仍然保留。',
    ),
  };
}
