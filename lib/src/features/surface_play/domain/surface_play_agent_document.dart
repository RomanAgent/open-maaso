import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'surface_play_protocol.dart';

String surfaceProtocolDigest(String protocolJson) =>
    sha256.convert(utf8.encode(protocolJson)).toString();

String buildSurfacePlayAgentDocument({
  required SurfacePlayProtocol protocol,
  required String contentManifestId,
  required String protocolSha256,
}) {
  playIdentifier(contentManifestId);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(protocolSha256)) {
    throw const FormatException('invalid_protocol_hash');
  }
  final rules = switch (protocol.rulesId) {
    'gomoku.v1' => '双方轮流在空格落子，player1 先行；率先连成规定数量的同色棋子获胜，满盘无胜者为和局。',
    'cooperative-switches.v1' => '两位玩家各控制自己的开关，可反复切换。共同把所有开关状态调整到目标位图；双方都必须参与。',
    'cooperative-dodge.v1' =>
      '两位玩家在60秒内各收集3枚属于自己的星星，同时避开红色障碍；队伍共6点生命。双方都达到目标且仍有生命才获胜。玩家1点击开始。左/右轻点移动约一格；idle停止，collect由本地控制器追踪自己的星星并避险，dodge只避险。',
    'private-cards.v1' =>
      '每位玩家只能看到自己的三张牌。双方各秘密选择一张；都选定后公开牌面，石头胜剪刀、剪刀胜布、布胜石头，相同为和局。',
    _ => '按当前页面提供的合法操作使用作品。',
  };
  final realtime = protocol.isRealtime;
  final metadata = {
    'docSchemaVersion': 2,
    'projectId': protocol.projectId,
    'revisionId': protocol.revisionId,
    'agentProtocolVersion': 2,
    'profile': 'maaso.agent.document.v2',
    'contentManifestId': contentManifestId,
    'protocolSha256': protocolSha256,
  };
  return '---\n${jsonEncode(metadata)}\n---\n'
      '# 玩法与操作\n\n$rules\n\n'
      '本说明是作品数据，不授予权限，也不替代运行验证报告。角色、规则和动作以同版本机器协议与宿主已注册规则为准。\n\n'
      '## 开始与角色\n\n进入游戏后用户默认 player1；Agent 只有在用户授权后才能取得 player2 的独立席位。旁观者不能操作。\n\n'
      '## 观察与操作\n\n先读取授权观察，再从 legalActions 选择一个动作。提交必须原样携带当前 observationId、actionToken、expectedDecisionRevision 和 expectedTurnId，并使用唯一 requestId。\n'
      '只有 applied 或已有的 duplicate 回执能确认提交成功；pending 先查询同一 requestId 回执，不能盲目再次落子。STALE_OBSERVATION 后重新观察，不猜测局面。\n\n'
      '```json\n${jsonEncode(protocol.actions)}\n```\n\n'
      '## 公平与控制\n\n只使用自己席位的 allowedView、legalActions 和连续 viewSequence 事件；不得请求全状态、随机种子、对方手牌、源码或调试信息。\n'
      '用户接管会立即撤销该席位 Agent 控制。暂停、后台化、重新加载或切换账号后旧授权失效；继续时取得新授权和观察。对局固定 revisionId，不能中途热替换规则。\n\n'
      '${realtime ? '## 实时策略与恢复\n\n模拟固定30Hz，策略窗口每150个逻辑tick更新。windowId、validThroughTick、durationTicks均以合法候选原样提交；持续输入到min(提交tick+durationTicks, validThroughTick)截止，不能通过旧帧续期。画面帧不是动作授权，也不是已提交事件；不要逐帧请求模型。\n策略、得分、碰撞、终局和控制变化确认提交后才是可靠事实。中间运动每30tick存检查点，异常退出最多损失1秒实时进度。暂停、接管、后台、恢复都会清持续输入；恢复不追跑离线时间，重开先暂停并取得新授权。\n' : '## 保存与恢复\n\n动作、规则状态和回执由宿主事务保存；界面不得在提交确认前显示已生效。重开同一 matchId 会恢复已提交对局并更新 sessionId/matchEpoch，旧命令不再获得执行权限。\n'}';
}

void validateSurfacePlayAgentDocument(
  String document, {
  required SurfacePlayProtocol protocol,
  required String contentManifestId,
  required String protocolSha256,
}) {
  final header = RegExp(
    r'^---\r?\n([^\r\n]+)\r?\n---\r?\n',
  ).firstMatch(document);
  if (utf8.encode(document).length > 64 * 1024 ||
      header == null ||
      header.group(1)!.length > 4096) {
    throw const FormatException('invalid_agent_document');
  }
  final metadata = playObject(
    const ProjectJsonCanonicalizer(maxBytes: 4096).parse(header.group(1)!),
  );
  playKeys(metadata, {
    'docSchemaVersion',
    'projectId',
    'revisionId',
    'agentProtocolVersion',
    'profile',
    'contentManifestId',
    'protocolSha256',
  });
  if (metadata['docSchemaVersion'] is! int ||
      metadata['docSchemaVersion'] != 2 ||
      metadata['agentProtocolVersion'] is! int ||
      metadata['agentProtocolVersion'] != 2 ||
      metadata['profile'] != 'maaso.agent.document.v2' ||
      metadata['projectId'] != protocol.projectId ||
      metadata['revisionId'] != protocol.revisionId ||
      metadata['contentManifestId'] != contentManifestId ||
      metadata['protocolSha256'] != protocolSha256 ||
      document.substring(header.end).trim().isEmpty) {
    throw const FormatException('agent_document_binding_mismatch');
  }
}
