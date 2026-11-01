import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_interaction_grant.dart';

void main() {
  test('explicit edits bind one operation to the visible surface id', () {
    for (final text in const <String>[
      '再加一行文字',
      '把当前页面标题改成旅行计划',
      'please update the chart colors',
      'could you add one more row?',
      '增加一个预算功能',
      '新增一个预算功能',
      '在这个小程序里增加预算功能',
      '删除天气功能',
      '去掉天气功能',
      '帮我移除天气功能',
      'add a budget feature',
      'please remove the weather feature',
    ]) {
      final request = SurfaceInteractionAuthority.resolve(
        text: text,
        activeSurfaceId: 'surface-1',
      );
      expect(
        request?.operation,
        SurfaceInteractionOperation.edit,
        reason: text,
      );
      expect(request?.targetSurfaceId, 'surface-1', reason: text);
      expect(request?.methodName, 'editSurface', reason: text);
    }
  });

  test('revert exposes only its matching method', () {
    expect(
      SurfaceInteractionAuthority.resolve(
        text: '撤销刚才的修改',
        activeSurfaceId: 'surface-1',
      )?.methodName,
      'revertSurface',
    );
    expect(
      SurfaceInteractionAuthority.resolve(
        text: 'list my surfaces',
        activeSurfaceId: '',
      ),
      isNull,
    );
  });

  test('questions, negations and ordinary chat grant no interaction', () {
    for (final text in const <String>[
      'How do I edit a dashboard?',
      'What changes make a chart clearer?',
      'Could you explain how to add a line?',
      'Tell me how to edit this page',
      '告诉我怎么修改这个页面',
      '修改这个页面要注意什么？',
      '编辑这个页面需要多久？',
      '修改这个页面的流程是什么？',
      '编辑这个页面的风险有哪些？',
      '修改这个页面用什么方式？',
      '编辑这个页面从哪里开始？',
      '撤销这次修改难不难？',
      'Edit this page or rebuild it—which is safer?',
      'Could you edit this page or rebuild it—which is safer?',
      '可以帮我修改这个页面还是重做更安全？',
      'Revert this page—what would happen?',
      'Could you edit this page or rebuild it—which is safer',
      '可以帮我修改这个页面还是重做更安全',
      'Revert this page—what would happen',
      "don't edit this page",
      '不要修改这个界面',
      '不要增加预算功能',
      '先别新增功能',
      '不要删除预算功能',
      '暂不移除天气功能',
      '编辑这个小程序，但不要去掉天气功能',
      "don't add a budget feature",
      "do not remove the weather feature",
      "Edit this page but don't save the changes",
      '修改这个页面，先别保存',
      "Edit this page but don't show it",
      "Update this page but don't reopen it",
      '修改这个页面，但不要展示',
      '编辑这个页面，先别重新打开',
      'tell me a joke',
    ]) {
      expect(
        SurfaceInteractionAuthority.resolve(
          text: text,
          activeSurfaceId: 'surface-1',
        ),
        isNull,
        reason: text,
      );
    }
  });

  test('no visible surface means no interaction authority', () {
    expect(
      SurfaceInteractionAuthority.resolve(text: '再加一行文字', activeSurfaceId: ''),
      isNull,
    );
  });

  test('polite Chinese edit requests remain authorized', () {
    for (final text in const <String>['可以帮我修改这个页面吗？', '可以修改这个页面吗']) {
      final request = SurfaceInteractionAuthority.resolve(
        text: text,
        activeSurfaceId: 'surface-1',
      );

      expect(
        request?.operation,
        SurfaceInteractionOperation.edit,
        reason: text,
      );
      expect(request?.targetSurfaceId, 'surface-1', reason: text);
    }
  });
}
