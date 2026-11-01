import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'support/localized_copy_scan.dart';

void main() {
  test('literal interface translation keys exist in every bundle', () {
    final literalTranslation = RegExp(
      r'''(['"])([a-z][a-z0-9_.-]+)\1\.tr(?:Params)?\b''',
    );
    final missing = <String>[];
    final files = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in files) {
      final source = file.readAsStringSync();
      for (final match in literalTranslation.allMatches(source)) {
        final key = match.group(2)!;
        if (enUS.containsKey(key) && zhCH.containsKey(key)) continue;
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        missing.add('${file.path}:$line: $key');
      }
    }

    expect(missing, isEmpty);
  });

  test('fixed user-visible English copy is translated or explicitly allowed', () {
    final files = <File>[
      ...Directory('lib/src/features')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.dart') &&
                file.path.contains('/presentation/'),
          ),
      ...Directory('lib/src/core/widgets')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      File('lib/src/app/routing/router_config.dart'),
    ];
    final sinks = <RegExp>[
      RegExp(
        r"""\b(?:Text|SelectableText|Tab)\s*\(\s*'([^'\n]*)'""",
        multiLine: true,
      ),
      RegExp(
        r'''\b(?:Text|SelectableText|Tab)\s*\(\s*"([^"\n]*)"''',
        multiLine: true,
      ),
      RegExp(
        r"""\b(?:tooltip|semanticLabel|labelText|hintText|helperText|helpText|message|label|title|subtitle)\s*:\s*'([^'\n]*)'""",
        multiLine: true,
      ),
      RegExp(
        r'''\b(?:tooltip|semanticLabel|labelText|hintText|helperText|helpText|message|label|title|subtitle)\s*:\s*"([^"\n]*)"''',
        multiLine: true,
      ),
    ];
    final asciiWord = RegExp(r'[A-Za-z]{2,}');
    final translationKey = RegExp(r'^[a-z0-9_]+(?:\.[a-z0-9_]+)+$');
    // Product names and protocol/measurement labels intentionally remain
    // stable across locales. Every addition here needs the same justification.
    const allowed = <String>{
      'Maaso',
      'Masso',
      'Google',
      'Apple',
      'OpenAI',
      'Anthropic',
      'Gemini',
      'DeepSeek',
      'SN',
      'dBm',
      // ISO calendar input notation is a language-independent format contract,
      // not business copy. Do not generalize this to arbitrary upper-case text.
      'YYYY-MM-DD',
    };
    final offenders = <String>[];

    for (final file in files) {
      final source = file.readAsStringSync();
      for (final sink in sinks) {
        for (final match in sink.allMatches(source)) {
          final value = match.group(1)!;
          if (value.contains(r'$')) continue;
          if (!asciiWord.hasMatch(value) ||
              translationKey.hasMatch(value) ||
              allowed.contains(value)) {
            continue;
          }
          final suffix = source.substring(
            match.end,
            (match.end + 12).clamp(0, source.length),
          );
          if (suffix.trimLeft().startsWith('.tr')) continue;
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          offenders.add('${file.path}:$line: $value');
        }
      }
    }

    expect(offenders, isEmpty);
  });

  test('presentation files do not hard-code Chinese interface copy', () {
    final files = Directory('lib/src/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.dart') &&
              file.path.contains('/presentation/'),
        );

    expect(
      unlocalizedChineseCopy({
        for (final file in files) file.path: file.readAsStringSync(),
      }),
      isEmpty,
    );
  });

  test('Chinese-copy scan permits real locale pairs and rejects business leaks', () {
    final approved = <String, String>{
      'locale.dart': '''
String text(context, String en, String zh) =>
  Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
void page(context) { Text(text(context, 'Hello', '你好')); }
''',
      'condition.dart': '''
void page(context) {
 final chinese = Localizations.localeOf(context).languageCode == 'zh';
 Text(chinese ? '重试' : 'Retry');
}
''',
      'comment.dart': "// 中文注释不是界面文案。\n/* 说明 */\nvoid page(){ Text('Maaso'); }",
      'inverse.dart':
          "void page(context){Text(Localizations.localeOf(context).languageCode!='zh'?'English':'中文');}",
      'confined.dart': '''
class Labels {
 String tr(String en,String zh)=>Localizations.localeOf(context).languageCode=='zh'?zh:en;
 String _state()=> '已开启';
 void page(){Text(tr('Enabled','状态：\${_state()}'));}
}
''',
    };
    expect(unlocalizedChineseCopy(approved), isEmpty);
    for (final source in <String>[
      "void page(){ Text('未翻译的业务文案'); }",
      "void page(){ const chinese=true; Text(chinese ? '中文' : 'English'); }",
      "String text(String en,String zh)=>en; void page(){Text(text('Hello','泄漏'));}",
      "void page(context){ final zh=Localizations.localeOf(context).languageCode=='zh'; Text(zh?'中文':'另一段中文');}",
      "void page(){ const payload=('任意业务数据','Data'); Text(payload.\$1); }",
      "void page(context){ final zh=Localizations.localeOf(context).languageCode=='zh'; Text('漏掉的前缀 \${zh ? '中文' : 'English'}');}",
      "String text(bool? allow)=>(allow??(Localizations.localeOf(context).languageCode=='zh'))?'未翻译泄漏':'English';",
      "String text()=>Localizations.localeOf(context).languageCode=='zh'?'English':'未翻译泄漏';",
      "class Safe{bool get zh=>Localizations.localeOf(context).languageCode=='zh';String text(String zh,String en)=>this.zh?zh:en;Object page(Bad bad)=>bad.text('未翻译泄漏','English');}class Bad{String text(String zh,String en)=>zh;}",
      "void page(context){var zh=Localizations.localeOf(context).languageCode=='zh';zh=true;Text(zh?'泄漏':'English');}",
      "class Box{Box({required this.zh});final bool zh;String text(String en,String cn)=>zh?cn:en;void page(){Text(text('English','泄漏'));}} void main(context){Box(zh:Localizations.localeOf(context).languageCode=='zh');Box(zh:true);}",
      "class Labels{String tr(String en,String zh)=>Localizations.localeOf(context).languageCode=='zh'?zh:en;String _state()=>'泄漏';void page(){Text(tr('状态 \${_state()}','中文'));}}",
      "class Labels{String tr(String en,String zh)=>Localizations.localeOf(context).languageCode=='zh'?zh:en;String _state()=>'泄漏';void page(){Text(tr('English','中文 \${_state()}'));final callback=_state;callback();}}",
    ]) {
      expect(
        unlocalizedChineseCopy({'negative.dart': source}),
        isNotEmpty,
        reason: source,
      );
    }
    expect(
      unlocalizedChineseCopy({
        'safe.dart':
            "class _Box{_Box({required this.zh});final bool zh;String tr(String en,String cn)=>zh?cn:en;void page(){Text(tr('English','中文'));}}void main(context){_Box(zh:Localizations.localeOf(context).languageCode=='zh');}",
        'bad.dart':
            "class _Box{_Box({required this.zh});final bool zh;String tr(String en,String cn)=>zh?cn:en;void page(){Text(tr('English','泄漏'));}}void main(){_Box(zh:true);}",
      }),
      allOf(isNotEmpty, everyElement(startsWith('bad.dart:'))),
    );
  });

  test('feature status sources do not hard-code Chinese interface copy', () {
    final chinese = RegExp(r'[\u3400-\u9fff]');
    const paths = <String>[
      'lib/src/features/agent_space/presentation/agent_space_page.dart',
      'lib/src/features/agent_space/application/agent_space_controller.dart',
      'lib/src/core/services/media_share_gateway.dart',
    ];
    final offenders = <String>[];

    for (final path in paths) {
      final sourceWithoutLineComments = File(path)
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      if (chinese.hasMatch(sourceWithoutLineComments)) offenders.add(path);
    }

    expect(offenders, isEmpty);
  });

  test('Chinese-copy scan separates direct search data from displayed labels', () {
    expect(
      unlocalizedChineseCopy({
        'search.dart':
            "bool matches(bool female, String query) => (female ? 'female 女性 女生' : 'male 男性').contains(query);",
        'display.dart': "void page(){Text('女性');}",
        'reused.dart':
            "void page(String query){final words='女性';Text(words);words.contains(query);}",
      }),
      allOf(
        hasLength(2),
        contains(startsWith('display.dart:')),
        contains(startsWith('reused.dart:')),
      ),
    );
  });

  test('interface status sources do not expose raw exception prose', () {
    const paths = <String>[
      'lib/src/core/services/auth_session_service.dart',
      'lib/src/features/skills/application/skill_store_controller.dart',
    ];
    final rawAssignment = RegExp(
      r'''(?:error|interactionError|statusMessage|notice|warning)\.value\s*=\s*(?:exception|failure|error)(?:\.toString\(\)|\.message)''',
    );
    final rawReturn = RegExp(
      r'''return\s+(?:exception|failure|error)\.toString\(\)''',
    );
    final offenders = <String>[];

    for (final path in paths) {
      final source = File(path).readAsStringSync();
      if (rawAssignment.hasMatch(source) || rawReturn.hasMatch(source)) {
        offenders.add(path);
      }
    }

    expect(offenders, isEmpty);
  });

  test('Agent runtime canned responses use localization keys', () {
    final source = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    for (final key in const <String>[
      'agent_runtime.handoff.weather',
      'agent_runtime.duplicate_game',
      'agent_runtime.duplicate_cancelled',
      'agent_runtime.no_retry_task',
      'agent_runtime.retry_wait',
      'agent_runtime.retry_context_missing',
      'agent_runtime.background_game_started',
      'agent_runtime.background_game_retried',
    ]) {
      expect(source, contains(key));
    }

    for (final legacyCopy in const <String>[
      '我在看天气。',
      '这个小游戏已经生成过了。你要覆盖之前的，还是重新生成一个新的？',
      '好的，这次先不覆盖也不重新生成。',
      '还没有可以重试的生成任务。',
      '我找不到上次生成任务的上下文了，你再说一遍需求我重新做。',
      '我开始做这个小游戏，生成好会直接打开。',
      '我重新开始生成这个小游戏。',
    ]) {
      expect(source, isNot(contains(legacyCopy)));
    }
  });
}
