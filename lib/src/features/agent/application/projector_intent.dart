const projectorTerms = [
  'projector',
  'yoturetoys',
  'bluetooth',
  '投影',
  '投影仪',
  '投屏',
  '蓝牙',
  '传图',
];

bool textContainsAny(String haystack, Iterable<String> needles) {
  for (final needle in needles) {
    if (haystack.contains(needle)) return true;
  }
  return false;
}

bool isProjectorMediaChoiceContext(String recentConversation) {
  final tail = _latestConversationTail(recentConversation);
  final context = tail.assistant.toLowerCase();
  final precedingUser = tail.user.toLowerCase();
  final hasProjectorContext =
      textContainsAny(context, projectorTerms) ||
      textContainsAny(precedingUser, projectorTerms);
  if (context.isEmpty || !hasProjectorContext) {
    return false;
  }
  final mentionsMedia = textContainsAny(context, const [
    'gallery',
    'online',
    'web image',
    'find one online',
    'photo',
    'picture',
    'image',
    '相册',
    '图库',
    '网络图片',
    '网上',
    '图片',
    '照片',
  ]);
  if (!mentionsMedia) return false;

  final offersGallery = textContainsAny(context, const [
    'gallery',
    'camera roll',
    '相册',
    '图库',
  ]);
  final offersOnline = textContainsAny(context, const [
    'online',
    'web',
    'internet',
    '网上',
    '网络',
  ]);
  final asksForChoice =
      context.contains('?') ||
      context.contains('？') ||
      textContainsAny(context, const [
        'want to',
        'would you',
        'which image',
        'what image',
        'choose',
        'pick one',
        'should i find',
        '想要',
        '想用',
        '选择',
        '选一个',
        '要哪',
        '哪张',
        '什么图',
        '要不要',
        '还是',
      ]);
  return (offersGallery && offersOnline) || asksForChoice;
}

/// Returns only the latest user-to-assistant exchange from a role-labelled
/// transcript.
///
/// Projector follow-ups are a one-turn conversational obligation. Scanning the
/// entire prompt history lets an old projector question steal unrelated later
/// turns, even after the user and Agent have already changed topics.
({String user, String assistant}) _latestConversationTail(String conversation) {
  final normalized = conversation.trim();
  if (normalized.isEmpty) return (user: '', assistant: '');
  final rolePattern = RegExp(
    r'^(user|assistant|agent|system|tool)\s*:\s*',
    caseSensitive: false,
    multiLine: true,
  );
  final matches = rolePattern.allMatches(normalized).toList(growable: false);
  if (matches.isEmpty) return (user: '', assistant: normalized);
  final latest = matches.last;
  final role = latest.group(1)?.toLowerCase();
  if (role != 'assistant' && role != 'agent') {
    return (user: '', assistant: '');
  }
  var user = '';
  if (matches.length >= 2) {
    final preceding = matches[matches.length - 2];
    if (preceding.group(1)?.toLowerCase() == 'user') {
      user = normalized.substring(preceding.end, latest.start).trim();
    }
  }
  return (user: user, assistant: normalized.substring(latest.end).trim());
}

String normalizeProjectorChoiceText(String text) {
  var lower = text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  lower = lower
      .replaceFirst(RegExp(r'\s+please$'), '')
      .replaceFirst(RegExp(r'\s+pls$'), '');
  return lower;
}

bool isProjectorGalleryChoiceText(String text) {
  final lower = normalizeProjectorChoiceText(text);
  if (const {
    'photo',
    'photos',
    'picture',
    'pictures',
    'gallery',
    'from gallery',
    'from my gallery',
    'my gallery',
    'use gallery',
    'choose gallery',
    'gallery photo',
    'photo from gallery',
    'photos from gallery',
    'picture from gallery',
    'pictures from gallery',
    '照片',
    '图片',
    '相册',
    '图库',
    '从相册',
    '从图库',
    '选照片',
    '用相册',
  }.contains(lower)) {
    return true;
  }
  final mentionsGallery = textContainsAny(lower, const [
    'gallery',
    'album picker',
    'camera roll',
    '相册',
    '图库',
  ]);
  final asksToUse = textContainsAny(lower, const [
    'send',
    'use',
    'with',
    'from',
    'choose',
    'pick',
    'open',
    '发送',
    '用',
    '从',
    '选择',
    '打开',
  ]);
  return mentionsGallery && asksToUse;
}

bool isProjectorOnlineImageChoiceText(String text) {
  final lower = normalizeProjectorChoiceText(text);
  if (const {
    'online',
    'web',
    'internet',
    'find one online',
    'find online',
    'search online',
    'web image',
    'online image',
    '网上找',
    '网络图片',
    '网上图片',
  }.contains(lower)) {
    return true;
  }
  final asksToFind = textContainsAny(lower, const [
    'find',
    'search',
    'look up',
    'google',
    'online',
    'web',
    'internet',
    '找',
    '搜',
    '搜索',
    '网上',
    '网络',
  ]);
  final wantsImage = textContainsAny(lower, const [
    'image',
    'picture',
    'photo',
    'pic',
    '图片',
    '照片',
    '图像',
    '配图',
    '插图',
  ]);
  return asksToFind && wantsImage;
}

bool isProjectorImageSubjectChoiceText(String text) {
  final lower = normalizeProjectorChoiceText(text);
  if (lower.isEmpty) return false;
  if (isProjectorGalleryChoiceText(text)) return false;
  if (const {
    'yes',
    'yeah',
    'yep',
    'ok',
    'okay',
    'no',
    'nope',
    'cancel',
    'stop',
    'never mind',
    '算了',
    '取消',
    '不要',
  }.contains(lower)) {
    return false;
  }
  if (textContainsAny(lower, const [
    'album',
    'blog',
    'dashboard',
    'card',
    'game',
    'mini app',
    'widget',
    '相册',
    '博客',
    '看板',
    '卡片',
    '游戏',
    '小程序',
    '小组件',
  ])) {
    return false;
  }
  if (_looksLikeOrdinaryCommand(lower)) return false;
  if (lower.length > 80) return false;
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(lower);
}

bool _looksLikeOrdinaryCommand(String normalized) {
  if (const {
    'hello',
    'hi',
    'hey',
    'good morning',
    'good afternoon',
    'good evening',
    '你好',
    '嗨',
    '哈喽',
    '早上好',
    '下午好',
    '晚上好',
  }.contains(normalized)) {
    return true;
  }
  return RegExp(
        r'^(say|speak|talk|chat|tell|explain|translate|answer|write|play|sing|read|open|close|connect|disconnect|turn|call|remind|set|what|why|how|who|when|where|can|could|would|do|does|did|are|is|will|should)\b',
        caseSensitive: false,
      ).hasMatch(normalized) ||
      RegExp(
        r'^(说|说声|讲|聊|告诉|解释|翻译|回答|写|播放|唱|读|打开|关闭|连接|断开|提醒|设置|什么|为什么|怎么|如何|谁|哪里|几点)',
      ).hasMatch(normalized);
}

bool isProjectorMediaChoiceText(String text) =>
    isProjectorGalleryChoiceText(text) ||
    isProjectorOnlineImageChoiceText(text);

bool isProjectorMediaFollowUp(String text, String recentConversation) =>
    (isProjectorMediaChoiceText(text) ||
        isProjectorImageSubjectChoiceText(text)) &&
    isProjectorMediaChoiceContext(recentConversation);

bool isProjectorOnlineImageFollowUp(String text, String recentConversation) =>
    (isProjectorOnlineImageChoiceText(text) ||
        isProjectorImageSubjectChoiceText(text)) &&
    isProjectorMediaChoiceContext(recentConversation);

bool isProjectorImageSubjectFollowUp(String text, String recentConversation) =>
    isProjectorImageSubjectChoiceText(text) &&
    isProjectorMediaChoiceContext(recentConversation);
