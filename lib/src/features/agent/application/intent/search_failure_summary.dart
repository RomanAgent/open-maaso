import 'dart:convert';

import 'package:maaso/src/core/services/locale_config_service.dart';

/// Reports known transport outcomes; model prose cannot relabel a failed call.
/// Unknown or successful receipts keep the existing answer-generation path.
String? searchFailureSummary(List<String> observations, AppLocale locale) {
  final failures = <Map<String, dynamic>>[];
  for (final observation in observations) {
    if (!observation.startsWith('skill.call skill_websearch_') ||
        observation.startsWith('skill.call skill_websearch_imagesearch')) {
      continue;
    }
    final marker = observation.indexOf(' => ');
    if (marker < 0) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(observation.substring(marker + 4));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final results = decoded['results'];
    if (results is List && results.isNotEmpty) return null;
    final status = decoded['status'];
    if (status != 'failed' &&
        status != 'no_results' &&
        decoded['error'] is! String) {
      return null;
    }
    failures.add(decoded);
  }
  if (failures.isEmpty) return null;
  final zh = locale == AppLocale.zh;
  if (failures.any((value) => value['status'] == 'no_results')) {
    return zh
        ? '这次搜索没有找到能回答你问题的结果。你可以稍后让我重试。'
        : 'This search found no results that answer your question. You can ask me to try again later.';
  }
  final attempts = <Map>[
    for (final failure in failures)
      if (failure['attempts'] case final List values)
        ...values.whereType<Map>(),
  ];
  if (attempts.isNotEmpty &&
      attempts.every((attempt) => attempt['error'] == 'timeout')) {
    return zh
        ? '搜索来源都在等待结果时超时了，我没有收到可用结果。你可以稍后让我重试。'
        : 'All search sources timed out while waiting for results. I received no usable result; you can ask me to try again later.';
  }
  if (attempts.any(
    (attempt) =>
        attempt['error'] == 'challenge' || attempt['error'] == 'rate_limited',
  )) {
    return zh
        ? '部分搜索来源要求验证或限制了请求，备用来源也未返回可用结果。你可以稍后让我重试。'
        : 'Some search sources required verification or limited the request, and the fallback returned no usable result. You can ask me to try again later.';
  }
  return zh
      ? '搜索服务这次未能返回结果，暂时无法核实实时信息。你可以稍后让我重试。'
      : 'The search service could not return results, so I cannot verify current information yet. You can ask me to try again later.';
}
