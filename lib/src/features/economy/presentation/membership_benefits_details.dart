import 'package:flutter/material.dart';
import '../domain/membership_benefits.dart';

/// Shared by the comparison list and both human purchase confirmations.
class MembershipBenefitsDetails extends StatelessWidget {
  const MembershipBenefitsDetails({
    required this.model,
    required this.zh,
    this.terms,
    this.explainLimits = false,
    super.key,
  });
  final MembershipTierBenefits model;
  final bool zh, explainLimits;
  final ReviewedMembershipTerms? terms;
  String tr(String en, String cn) => zh ? cn : en;
  String number(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${model.tier.title} · ${model.displayName}',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      Text('${model.provider} · ${model.modelId}'),
      Text(
        tr(
          'Capability: ${model.capabilityClass} · Thinking: ${model.thinking}',
          '能力级别：${model.capabilityClass} · 思考模式：${model.thinking}',
        ),
      ),
      const SizedBox(height: 6),
      Text(
        tr(
          'Context: ${number(model.contextTokens)} tokens · Maximum output: ${number(model.maxOutputTokens)} tokens',
          '上下文：${number(model.contextTokens)} tokens · 单次输出上限：${number(model.maxOutputTokens)} tokens',
        ),
      ),
      if (model.quotaUnlimited)
        Text(tr('Model usage: unlimited', '模型用量：不限额'))
      else ...[
        Text(
          tr(
            'Daily: ${number(model.dailyTokens)} tokens · ${number(model.dailyRequests)} requests',
            '每日额度：${number(model.dailyTokens)} tokens · ${number(model.dailyRequests)} 次请求',
          ),
        ),
        Text(
          tr(
            'Per service period: ${number(model.grantTokens)} tokens',
            '每个服务周期：${number(model.grantTokens)} tokens',
          ),
        ),
      ],
      if (explainLimits && !model.quotaUnlimited) ...[
        const SizedBox(height: 8),
        Text(
          tr(
            'Input and output use the token allowance. Both daily and service-period limits apply; daily limits reset at 00:00 UTC. Unused period allowance expires.',
            '输入和输出均计入 token 额度，每日和整期上限同时生效；每日额度于 UTC 00:00 重置。未用完的整期额度到期失效。',
          ),
        ),
      ],
      if (terms case final reviewed?) ...[
        const SizedBox(height: 8),
        Text(
          tr(
            'Offer version: ${reviewed.policyVersion}',
            '购买版本：${reviewed.policyVersion}',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          tr(
            'Model policy: ${reviewed.entitlementVersion}',
            '模型权益版本：${reviewed.entitlementVersion}',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ],
  );
}
