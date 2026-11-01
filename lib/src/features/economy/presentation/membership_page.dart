import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/membership_page_adapter.dart';
import '../application/membership_review.dart';
import '../application/membership_selection_controller.dart';
import '../application/store_purchase_service.dart';
import '../domain/economy_models.dart';
import 'membership_benefits_details.dart';
import 'store_payment_message.dart';

class MembershipPage extends StatefulWidget {
  const MembershipPage({
    super.key,
    required this.route,
    this.service,
    this.uiControl,
  });
  final String route;
  final StorePurchaseService? service;
  final AgentUiControlService? uiControl;
  @override
  State<MembershipPage> createState() => _MembershipPageState();
}

class _MembershipPageState extends State<MembershipPage>
    with WidgetsBindingObserver {
  late MembershipSelectionController _controller;
  AgentUiControlService? _control;
  MembershipPageAdapter? _adapter;
  PageAgentAdapterRegistration<MembershipPageAdapter>? _registration;
  bool get zh => Localizations.localeOf(context).languageCode == 'zh';
  String tr(String en, String cn) => zh ? cn : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mount();
  }

  void _mount() {
    _controller = MembershipSelectionController(
      service: widget.service ?? appServices.maybeFind<StorePurchaseService>(),
    );
    _control =
        widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    if (_control case final control?) {
      _adapter = MembershipPageAdapter(
        route: widget.route,
        controller: _controller,
        coordinator: control.coordinator,
      );
      _registration = control.adapters.register(_adapter!);
    }
    unawaited(_controller.refresh());
  }

  void _unmount() {
    _adapter?.detach();
    _registration?.unregister();
    _controller.onClose();
  }

  @override
  void didUpdateWidget(covariant MembershipPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        oldWidget.route != widget.route ||
        oldWidget.uiControl != widget.uiControl) {
      _unmount();
      _mount();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unmount();
    super.dispose();
  }

  void _takeOver() => _control?.coordinator.pauseForUserActivity(
    reason: 'membership_user_control',
  );
  Future<void> _restore() async {
    _takeOver();
    final c = _controller;
    final service = c.service;
    if (!c.active || c.busy || service == null) return;
    c.restoring.value = true;
    try {
      await service.restore();
      if (c.active) await service.load();
    } catch (_) {
      if (c.active) service.error.value ??= 'store_unavailable';
    } finally {
      if (c.active) c.restoring.value = false;
    }
  }

  Future<void> _manage() async {
    _takeOver();
    final platform = defaultTargetPlatform;
    final url = switch (platform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS => 'https://apps.apple.com/account/subscriptions',
      TargetPlatform.android =>
        'https://play.google.com/store/account/subscriptions',
      _ => null,
    };
    var opened = false;
    try {
      if (url != null) {
        opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          appGlassSnackBar(
            content: Text(
              tr(
                'Open subscriptions in the store where you subscribed.',
                '请在购买时使用的系统商店中管理订阅。',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _buy() async {
    _takeOver();
    final c = _controller;
    if (!c.canBuy) return;
    final service = c.service!;
    final product = c.productFor(c.selectedTier.value!)!;
    c.reviewing.value = true;
    try {
      final terms = reviewMembershipTerms(
        await service.readMembershipAvailability(),
        product.product.tier!,
      );
      if (!mounted || !identical(c, _controller) || !c.active) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AppReactiveBuilder(() {
          final current =
              c.active && identical(c, _controller) && !service.busy.value;
          return AlertDialog(
            title: Text(tr('Review membership', '确认会员')),
            content: SingleChildScrollView(
              child: !current
                  ? Text(
                      tr(
                        'Your account changed. Reopen membership.',
                        '账号已变化，请重新打开会员页。',
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${product.product.tier!.title} · ${product.price} / ${tr('month', '月')}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        MembershipBenefitsDetails(
                          model: terms.model,
                          zh: zh,
                          explainLimits: true,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          tr(
                            'Monthly auto-renewing subscription. The store confirms your local price and billing date. Cancel renewal in the store. Coin passes cannot be exchanged while auto-renewal is active.',
                            '按月自动续费，商店将确认当地价格与扣款日期。可在系统订阅中取消续费。自动续费开启时不能兑换币兑通行证。',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          tr(
                            'If an already-paid renewal overlaps existing benefits, its full duration is queued after them. Store billing and service dates can differ.',
                            '若已付款续费与现有权益重叠，将保留全部购买时长并顺延；商店扣款日可能与服务生效日不同。',
                          ),
                        ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _takeOver();
                  Navigator.pop(context, false);
                },
                child: Text(tr('Cancel', '取消')),
              ),
              FilledButton(
                key: const ValueKey('membership-human-confirm'),
                onPressed: current
                    ? () {
                        _takeOver();
                        Navigator.pop(context, true);
                      }
                    : null,
                child: Text(tr('Continue to store', '前往商店确认')),
              ),
            ],
          );
        }),
      );
      if (confirmed != true ||
          !mounted ||
          !identical(c, _controller) ||
          !c.active) {
        return;
      }
      await service.buy(product, expectedPolicyVersion: terms.policyVersion);
    } catch (error) {
      if (c.active) {
        service.error.value = error is EconomyException
            ? error.code
            : 'membership_details_unavailable';
      }
    } finally {
      if (c.active) c.reviewing.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final compactHeight = MediaQuery.sizeOf(context).height < 500;
    return Listener(
      onPointerDown: (_) {
        _controller.setUserControl(true);
        _takeOver();
      },
      onPointerUp: (_) => _controller.setUserControl(false),
      onPointerCancel: (_) => _controller.setUserControl(false),
      child: AppSecondaryScaffold(
        contentMaxWidth: 680,
        header: AppSecondaryHeader(
          title: tr('Maaso membership', 'Maaso 会员'),
          onBack: () => appNavigation.pop(),
        ),
        bottomBar: compactHeight ? null : _footer(),
        body: AppReactiveBuilder(() {
          final c = _controller;
          final service = c.service;
          final usage = c.usage;
          return ListView(
            key: const ValueKey('membership-plans-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    tr('Choose your companion plan', '选择适合你的陪伴'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  TextButton(
                    key: const ValueKey('membership-restore'),
                    onPressed: c.active && !c.busy ? _restore : null,
                    child: Text(
                      c.restoring.value
                          ? tr('Restoring…', '恢复中…')
                          : tr('Restore purchases', '恢复购买'),
                    ),
                  ),
                ],
              ),
              Text(
                usage == null
                    ? tr('Membership status unavailable', '会员状态暂不可用')
                    : tr(
                        'Current: ${c.currentTier?.title ?? 'Free'}',
                        '当前方案：${c.currentTier?.title ?? 'Free'}',
                      ),
                key: const ValueKey('membership-current'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (service?.loading.value == true && c.active)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(),
                ),
              if (!c.active)
                _notice(
                  tr(
                    'Membership services are unavailable. Reopen this page after signing in.',
                    '会员服务暂不可用，请登录后重新打开。',
                  ),
                ),
              if (c.active && service!.error.value != null)
                _notice(
                  storePaymentMessage(service.error.value!, zh),
                  error: true,
                ),
              if (c.active && service!.hasUnresolved)
                _notice(
                  tr(
                    'Your purchase is awaiting confirmation. Restore or refresh the same purchase; do not pay again.',
                    '购买正在确认，请恢复或刷新同一笔购买，无需再次付款。',
                  ),
                ),
              _plan(null),
              for (final tier in MembershipTier.currentTiers) _plan(tier),
              const SizedBox(height: 4),
              Text(
                tr(
                  'Plans use the model shown above. Local store prices and full benefits are confirmed before purchase.',
                  '对话使用所选方案对应的模型。购买前确认商店当地价格与完整权益。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('membership-refresh'),
                onPressed: c.active && !c.busy
                    ? () {
                        _takeOver();
                        unawaited(c.refresh());
                      }
                    : null,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('Refresh membership', '刷新会员状态')),
              ),
              if (c.active && c.currentTier != null)
                TextButton(
                  onPressed: _manage,
                  child: Text(tr('Manage subscription', '管理订阅')),
                ),
              if (c.active)
                for (final receipt in service!.receipts.where(
                  (r) => r.kind == 'membership',
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${receipt.tier?.title ?? tr('Membership', '会员')} · ${switch (receipt.state) {
                        'granted' => tr('Granted', '已生效'),
                        'revoked' => tr('Refunded or revoked', '已退款或撤销'),
                        _ => tr('Awaiting confirmation', '待确认'),
                      }}'
                      '${receipt.expiresAt == null ? '' : ' · ${_date(receipt.expiresAt!)}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              if (compactHeight) _footer(),
            ],
          );
        }),
      ),
    );
  }

  Widget _notice(String text, {bool error = false}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppSecondaryPalette.of(context).surfaceMuted,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(
          color: error ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    ),
  );
  Widget _plan(MembershipTier? tier) {
    final c = _controller;
    final colors = Theme.of(context).colorScheme;
    final palette = AppSecondaryPalette.of(context);
    final selected = c.selectedTier.value == tier;
    final current = c.usage != null && c.currentTier == tier;
    final product = tier == null ? null : c.productFor(tier);
    final title = tier?.title ?? 'Free';
    final price = tier == null
        ? tr('Free', '免费')
        : product?.price ?? tr('Price unavailable', '价格暂不可用');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        selected: selected,
        button: true,
        label:
            '$title, $price${tier == null ? '' : ' / ${tr('month', '月')}'}${current ? ', ${tr('current plan', '当前方案')}' : ''}',
        child: Material(
          color: selected ? palette.selectedSurface : palette.surfaceMuted,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('membership-select-${tier?.wireName ?? 'free'}'),
            onTap: c.active && !c.busy
                ? () {
                    _takeOver();
                    c.select(tier);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (current)
                            Text(
                              tr('Current', '当前'),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.primary),
                            ),
                        ],
                      ),
                      Text(
                        '$price${tier == null ? '' : ' / ${tr('month', '月')}'}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tier?.modelDisplayName ?? 'Doubao-Seed-Evolving',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 20,
                        color: selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                  if (tier != null && product == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        tr(
                          'Reference price · store price unavailable',
                          '参考价格 · 商店价格暂不可用',
                        ),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer() => AppReactiveBuilder(() {
    final c = _controller;
    final tier = c.selectedTier.value;
    final service = c.service;
    final current = c.usage != null && tier == c.currentTier;
    final manage = tier == null && c.usage != null && c.currentTier != null;
    String label;
    if (c.busy) {
      label = tr('Processing…', '正在处理…');
    } else if (c.active && service!.hasUnresolved) {
      label = tr('Purchase awaiting confirmation', '购买正在确认');
    } else if (service?.loading.value == true) {
      label = tr('Loading prices…', '正在获取价格…');
    } else if (current) {
      label = tr('Current plan', '当前方案');
    } else if (manage) {
      label = tr('Manage subscription', '管理订阅');
    } else if (c.canBuy) {
      label = tr(
        'Continue · ${c.productFor(tier!)!.price} / month',
        '继续 · ${c.productFor(tier)!.price} / 月',
      );
    } else {
      label = tr('Purchase unavailable', '暂不可购买');
    }
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.field,
          cornerRadius: 24,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('membership-purchase'),
                  onPressed: manage && !c.busy
                      ? _manage
                      : c.canBuy
                      ? _buy
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (c.busy) ...[
                          const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(label, textAlign: TextAlign.center),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tier == null && c.currentTier == null
                    ? tr('Free to use. No subscription required.', '免费使用，无需订阅。')
                    : tr(
                        'Renews monthly. Cancel in system subscriptions. The store confirms your price and billing date.',
                        '按月自动续费，可在系统订阅中取消。价格与扣款日期以商店确认为准。',
                      ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  });
  String _date(DateTime time) => time.toLocal().toString().substring(0, 10);
}
