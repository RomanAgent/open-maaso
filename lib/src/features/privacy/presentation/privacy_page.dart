import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import '../application/privacy_service.dart';
import '../data/privacy_http_client.dart';
import '../domain/privacy_models.dart';
import 'privacy_page_adapter.dart';

class PrivacyPage extends StatefulWidget {
  const PrivacyPage({super.key, this.service, this.openUrl, this.uiControl});
  final PrivacyService? service;
  final Future<bool> Function(Uri)? openUrl;
  final AgentUiControlService? uiControl;
  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<PrivacyPage> {
  final _form = GlobalKey<FormState>();
  final _birthDate = TextEditingController();
  late final PrivacyService _service;
  bool _ownsService = false;
  bool _ageConfirmed = false;
  String? _notice;
  bool _failed = false;
  AgentUiControlService? _uiControl;
  PrivacyPageAdapter? _adapter;
  PageAgentAdapterRegistration<PrivacyPageAdapter>? _registration;
  String _text(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    final owned = widget.service ?? appServices.maybeFind<PrivacyService>();
    if (owned != null) {
      _service = owned;
    } else {
      final gateway = PrivacyHttpClient(
        baseUri: () => appServices.find<AppEnvironmentService>().baseUri,
        accountId: () => '',
        accessToken: () async => '',
      );
      _service = PrivacyService(gateway: gateway, closeGateway: gateway.close);
      _ownsService = true;
    }
    _uiControl =
        widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    if (_uiControl != null) {
      _adapter = PrivacyPageAdapter(
        service: _service,
        coordinator: _uiControl!.coordinator,
      );
      _registration = _uiControl!.adapters.register(_adapter!);
    }
    // Both services publish Riverpod state. initState is still part of the
    // widget build boundary, including the production root ProviderScope.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_service.isCurrent) return;
      unawaited(_run(_service.refresh));
      // Existing identity is private bootstrap data; never create a profile,
      // birthday or consent merely to let this page continue.
      final identity = appServices.maybeFind<IdentityService>();
      if (_service.hasAccount && identity != null) {
        unawaited(() async {
          try {
            if (mounted && _service.isCurrent) await identity.load();
          } catch (_) {
            // IdentityService owns its failure/local-fallback state.
          }
        }());
      }
    });
  }

  @override
  void dispose() {
    _adapter?.detach();
    _registration?.unregister();
    _birthDate.dispose();
    if (_ownsService) _service.onClose();
    super.dispose();
  }

  void _takeOver() => _uiControl?.coordinator.pauseForUserActivity(
    reason: 'privacy_form_input',
  );

  Future<void> _run(
    Future<Object?> Function() operation, {
    String? success,
  }) async {
    try {
      await operation();
      if (mounted) {
        setState(() {
          _notice = success;
          _failed = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      final code = error is PrivacyException
          ? error.code
          : 'PRIVACY_UNAVAILABLE';
      setState(() {
        _failed = true;
        _notice = _errorText(code);
      });
    }
  }

  String _errorText(String code) => switch (code) {
    'PRIVACY_VOICE_STOP_PENDING' => _text(
      'Permission is withdrawn. An existing voice session is still stopping; refresh to check again.',
      '授权已撤回，已有语音会话仍在停止中，请稍后刷新查看。',
    ),
    'PRIVACY_POLICY_CHANGED' || 'PRIVACY_REVISION_CONFLICT' => _text(
      'The policy or your choices changed. Refresh and review them again.',
      '政策或授权状态已变化，请刷新后重新确认。',
    ),
    'PRIVACY_CONTEXT_CHANGED' || 'PRIVACY_AUTHENTICATION_REQUIRED' => _text(
      'Your account session changed. Reopen this page after signing in.',
      '账号状态已变化，请登录后重新打开此页。',
    ),
    'PRIVACY_INVALID_INPUT' => _text(
      'Check the date and try again.',
      '请检查出生日期后重试。',
    ),
    _ =>
      _service.hasAccount && !_service.canEnterOnlineFeatures
          ? _text(
              'Settings could not be synced yet. Your saved restrictions still apply.',
              '设置暂未同步，已保存的限制仍然生效。',
            )
          : _text(
              'This change could not be synced yet. You can keep using the app; choices you turned off remain off.',
              '本次设置暂未同步，你仍可继续使用；已关闭的选项会保持关闭。',
            ),
  };

  Future<void> _open(Uri uri) async {
    _takeOver();
    await _run(() async {
      final opened =
          await (widget.openUrl?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) throw const PrivacyException('PRIVACY_UNAVAILABLE');
      return opened;
    });
  }

  Future<void> _saveAge(PrivacySnapshot reviewed) async {
    _takeOver();
    if (!_ageConfirmed || !(_form.currentState?.validate() ?? false)) return;
    final date = _birthDate.text.trim();
    await _run(() async {
      final result = await _service.humanDeclareAge(
        reviewed: reviewed,
        birthDate: date,
      );
      if (mounted) {
        _birthDate.clear();
        _ageConfirmed = false;
      }
      return result;
    }, success: _text('Age declaration saved.', '年龄声明已保存。'));
  }

  Future<void> _chooseConsent(
    PrivacySnapshot reviewed,
    PrivacyRecipient recipient,
    String scope,
    bool allow,
  ) async {
    _takeOver();
    if (allow) {
      var confirmed = false;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(
              _text('Allow ${recipient.name}', '授权 ${recipient.name}'),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_scopeLabel(scope)),
                  const SizedBox(height: 12),
                  Text(recipient.dataCategories.join('\n')),
                  const SizedBox(height: 12),
                  Text(
                    _text(
                      'Policy: ${reviewed.policy!.version}. You can withdraw this permission here.',
                      '政策版本：${reviewed.policy!.version}。可随时在此撤回。',
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('privacy-consent-confirm'),
                    contentPadding: EdgeInsets.zero,
                    value: confirmed,
                    onChanged: (value) =>
                        update(() => confirmed = value == true),
                    title: Text(
                      _text('I agree to this data processing.', '我同意上述数据处理。'),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(_text('Cancel', '取消')),
              ),
              FilledButton(
                key: const Key('privacy-consent-submit'),
                onPressed: confirmed
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: Text(_text('Allow', '授权')),
              ),
            ],
          ),
        ),
      );
      if (accepted != true || !mounted) return;
    }
    await _run(
      () => _service.humanSetConsent(
        reviewed: reviewed,
        recipientId: recipient.id,
        scope: scope,
        allow: allow,
      ),
      success: allow
          ? _text('Permission saved.', '授权已保存。')
          : _text(
              'Permission withdrawn. New cloud requests will be blocked.',
              '授权已撤回，后续云端请求将被阻止。',
            ),
    );
  }

  String _scopeLabel(String scope) => switch (scope) {
    PrivacyScopes.cloudText => _text(
      'Cloud text and conversation context',
      '云端文本与对话上下文',
    ),
    PrivacyScopes.cloudVoice => _text(
      'Cloud speech and live audio/video',
      '云端语音与直播音视频',
    ),
    PrivacyScopes.cloudImage => _text(
      'Cloud image and video processing',
      '云端图片与视频处理',
    ),
    PrivacyScopes.contentModeration => _text(
      'Automated content review',
      '自动内容审核',
    ),
    _ => scope,
  };

  Widget _internalTestPage() => AppSecondaryScaffold(
    header: AppSecondaryHeader(
      title: _text('Internal test', '内部测试'),
      onBack: () => appNavigation.pop(),
    ),
    body: SafeArea(
      child: Listener(
        onPointerDown: (_) => _takeOver(),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  _text(
                    'This internal test build does not require the release privacy setup. You can continue testing.',
                    '当前为内部测试版，无需完成正式版隐私配置，可继续测试。',
                  ),
                  key: const Key('privacy-internal-test-info'),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('privacy-internal-test-continue'),
                  onPressed: () {
                    _takeOver();
                    if (!_service.isInternalTest) return;
                    appNavigation.go(
                      _service.canEnterOnlineFeatures
                          ? IdentityRoutePolicy.initialRoute()
                          : AppRouteCatalog.login,
                    );
                  },
                  child: Text(
                    _service.hasAccount
                        ? _text('Continue', '继续')
                        : _text('Sign in', '登录'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    if (_service.isInternalTest) return _internalTestPage();
    final snapshot = _service.snapshot;
    final policy = _service.publicPolicy?.policy ?? snapshot?.policy;
    final busy = _service.loading || _service.saving;
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: _text('Privacy & permissions', '隐私与授权'),
        onBack: () => appNavigation.pop(),
        trailing: IconButton(
          key: const Key('privacy-refresh'),
          tooltip: _text('Refresh status', '刷新状态'),
          onPressed: busy
              ? null
              : () {
                  _takeOver();
                  unawaited(_run(_service.refresh));
                },
          icon: const Icon(Icons.refresh),
        ),
      ),
      body: SafeArea(
        child: Listener(
          onPointerDown: (_) => _takeOver(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _notice!,
                          key: const Key('privacy-notice'),
                          style: TextStyle(
                            color: _failed && !_service.usesDefaultAvailability
                                ? Theme.of(context).colorScheme.error
                                : glass.foregroundPrimary,
                          ),
                        ),
                      ),
                    ),
                  if (_service.usesDefaultAvailability &&
                      _notice == null &&
                      (_service.canEnterOnlineFeatures || !_service.hasAccount))
                    Text(
                      _service.hasAccount
                          ? _text(
                              'Features are available by default. You can keep using the app while privacy settings sync; choices you turned off remain off.',
                              '功能默认可用，可在隐私设置同步期间继续使用；你已关闭的选项会保持关闭。',
                            )
                          : _text(
                              'Features are available by default after sign-in. Privacy details will appear here when available.',
                              '登录后可按默认设置使用功能，隐私详情将在加载后显示。',
                            ),
                      key: const Key('privacy-default-available'),
                    ),
                  if (policy != null) ...[
                    Text(
                      policy.operatorName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _text(
                        'Support: ${policy.supportEmail}',
                        '支持邮箱：${policy.supportEmail}',
                      ),
                    ),
                    Text(
                      _text(
                        'Policy ${policy.version} · Age ${policy.minimumAge}+',
                        '政策 ${policy.version} · ${policy.minimumAge} 岁及以上',
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => _open(policy.privacyUrl),
                          child: Text(_text('Privacy policy', '隐私政策')),
                        ),
                        TextButton(
                          onPressed: () => _open(policy.termsUrl),
                          child: Text(_text('Terms of service', '服务条款')),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    if (!_service.hasAccount)
                      Text(
                        _text(
                          'Sign in to declare your age and manage permissions.',
                          '登录后可申报年龄并管理授权。',
                        ),
                      ),
                    if (snapshot?.ageStatus == 'unconfirmed')
                      Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _text('Your age declaration', '年龄声明'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _text(
                                'Your birth date is stored privately to apply the age requirement. It is not shown on your profile or sent to model providers.',
                                '出生日期将私密保存，用于判断年龄要求；不会展示在个人资料中或发送给模型供应商。',
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              key: const Key('privacy-birth-date'),
                              controller: _birthDate,
                              enabled: !busy,
                              keyboardType: TextInputType.datetime,
                              maxLength: 10,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: _text('Birth date', '出生日期'),
                                hintText: 'YYYY-MM-DD',
                                border: const OutlineInputBorder(),
                              ),
                              onChanged: (_) {
                                _takeOver();
                                if (_ageConfirmed) {
                                  setState(() => _ageConfirmed = false);
                                }
                              },
                              validator: (value) {
                                final raw = value?.trim() ?? '';
                                final date = DateTime.tryParse(raw);
                                if (!RegExp(
                                      r'^\d{4}-\d{2}-\d{2}$',
                                    ).hasMatch(raw) ||
                                    date == null ||
                                    date.toIso8601String().substring(0, 10) !=
                                        raw ||
                                    date.year < 1900 ||
                                    date.isAfter(DateTime.now())) {
                                  return _text(
                                    'Enter a valid date as YYYY-MM-DD.',
                                    '请以 YYYY-MM-DD 填写有效日期。',
                                  );
                                }
                                return null;
                              },
                            ),
                            CheckboxListTile(
                              key: const Key('privacy-age-confirm'),
                              contentPadding: EdgeInsets.zero,
                              value: _ageConfirmed,
                              onChanged: busy
                                  ? null
                                  : (value) {
                                      _takeOver();
                                      setState(
                                        () => _ageConfirmed = value == true,
                                      );
                                    },
                              title: Text(
                                _text(
                                  'I confirm this is my birth date.',
                                  '我确认这是本人的出生日期。',
                                ),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                            FilledButton(
                              key: const Key('privacy-age-submit'),
                              onPressed: !busy && _ageConfirmed
                                  ? () => _saveAge(snapshot!)
                                  : null,
                              child: Text(
                                _text('Save age declaration', '保存年龄声明'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (snapshot?.ageStatus == 'ineligible')
                      Text(
                        _text(
                          'Online community and cloud services are unavailable because your declaration does not meet the ${policy.minimumAge}+ requirement.',
                          '根据你的年龄声明，尚未达到 ${policy.minimumAge} 岁的要求，暂不可使用在线社区和云端服务。',
                        ),
                      ),
                    if (snapshot?.ageEligible == true)
                      Text(
                        _text(
                          'Your declared age meets the current requirement.',
                          '你申报的年龄符合当前要求。',
                        ),
                      ),
                    const SizedBox(height: 24),
                    Text(
                      _text('Cloud permissions', '云端服务授权'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      _text(
                        'Choose each use separately. Local world production runs without a model call.',
                        '每项用途单独选择。微世界的规则生产无需调用模型。',
                      ),
                    ),
                    for (final recipient in policy.recipients)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                recipient.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(recipient.dataCategories.join('\n')),
                              TextButton(
                                onPressed: () => _open(recipient.policyUrl),
                                child: Text(
                                  _text('Provider privacy policy', '供应商隐私政策'),
                                ),
                              ),
                              if (snapshot != null)
                                for (final scope in recipient.scopes)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(_scopeLabel(scope)),
                                        OutlinedButton(
                                          key: Key(
                                            'privacy-choice-${recipient.id}-$scope',
                                          ),
                                          onPressed:
                                              !busy &&
                                                  (_service
                                                          .canEnterOnlineFeatures ||
                                                      snapshot.consents.any(
                                                        (c) =>
                                                            c.recipientId ==
                                                                recipient.id &&
                                                            c.scope == scope &&
                                                            c.allowed,
                                                      ))
                                              ? () => _chooseConsent(
                                                  snapshot,
                                                  recipient,
                                                  scope,
                                                  !_service.allowsLoadedConsent(
                                                    recipientId: recipient.id,
                                                    scope: scope,
                                                  ),
                                                )
                                              : null,
                                          child: Text(
                                            _service.allowsLoadedConsent(
                                                  recipientId: recipient.id,
                                                  scope: scope,
                                                )
                                                ? _text(
                                                    'On · Turn off',
                                                    '开启 · 关闭',
                                                  )
                                                : _text(
                                                    'Off · Review',
                                                    '关闭 · 查看并选择',
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 24),
                  if (_service.canEnterOnlineFeatures)
                    FilledButton(
                      key: const Key('privacy-continue'),
                      onPressed: () {
                        _takeOver();
                        appNavigation.go(IdentityRoutePolicy.initialRoute());
                      },
                      child: Text(_text('Continue', '继续')),
                    ),
                  if (_service.hasAccount)
                    TextButton(
                      onPressed: () {
                        if (_service.canEnterOnlineFeatures) {
                          appNavigation.go(IdentityRoutePolicy.initialRoute());
                          return;
                        }
                        final identity = appServices
                            .maybeFind<IdentityService>();
                        if (identity?.completed == true ||
                            identity?.continueLocally() == true) {
                          appNavigation.go(AppRouteCatalog.home);
                        } else {
                          appNavigation.go(AppRouteCatalog.login);
                        }
                      },
                      child: Text(_text('Back to companion', '返回陪伴')),
                    )
                  else
                    TextButton(
                      onPressed: () => appNavigation.go(AppRouteCatalog.login),
                      child: Text(_text('Sign in', '登录')),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  });
}
