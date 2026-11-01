String storePaymentMessage(String code, bool zh) => switch (code) {
  'membership_details_unavailable' || 'membership_policy_changed' =>
    zh
        ? '会员详情或价格版本已变化，请刷新后重新确认，尚未发起付款。'
        : 'Membership details or pricing changed. Refresh and review again; payment has not started.',
  'MEMBERSHIP_CAPACITY_UNAVAILABLE' || 'MEMBERSHIP_CAPABILITY_UNAVAILABLE' =>
    zh
        ? '当前会员模型或容量暂不可用，请刷新后再试，尚未发起付款。'
        : 'Membership models or capacity are unavailable. Refresh and try again; payment has not started.',
  'CASH_COIN_OVERLAP' =>
    zh
        ? '已有币兑通行证或商店订阅，暂不能新购现金会员。已付款的购买仍可恢复。'
        : 'An existing pass or subscription prevents new cash checkout. Existing purchases can still be restored.',
  'STORE_OWNERSHIP_CONFLICT' =>
    zh
        ? '此商店购买绑定了另一个 Maaso 账号，请切回购买时的账号恢复。'
        : 'This store purchase belongs to another Maaso account. Restore it using the original account.',
  'STORE_NOT_CONFIGURED' =>
    zh
        ? '商店服务或购买版本暂不可用，请刷新详情后重新确认；已有购买记录仍可查看。'
        : 'Store services or offer versions are unavailable. Refresh and review again; existing receipts remain accessible.',
  'store_fulfillment_pending' =>
    zh
        ? '付款凭据已保存，权益等待自动补发，无需再次购买。'
        : 'Your payment receipt is saved. Benefits will be delivered automatically; do not buy again.',
  'STORE_REVOKED' =>
    zh
        ? '商店已退款或撤销此购买，对应权益已撤销。'
        : 'The store refunded or revoked this purchase and its benefits.',
  'store_cancelled' => zh ? '购买已取消。' : 'Purchase cancelled.',
  'store_rejected' =>
    zh ? '商店未完成购买。' : 'The store did not complete this purchase.',
  'MEMBERSHIP_QUOTA_EXHAUSTED' || 'QUOTA_EXHAUSTED' =>
    zh
        ? '本期模型额度已用完，请在会员页面查看当前权益。'
        : 'Your model allowance is exhausted. Check your current benefits on the membership page.',
  'context_changed' =>
    zh ? '账号已变化，请重新打开购买页面。' : 'Your account changed. Reopen the purchase page.',
  _ =>
    zh
        ? '购买状态尚未确认，请恢复或重试同一购买，不要重复付款。'
        : 'Purchase status is unconfirmed. Restore or retry the same purchase instead of paying again.',
};
