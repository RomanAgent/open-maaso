import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

SurfaceProject project(String js) => SurfaceProject.fromJson({
  'id': 'delimiter-probe',
  'title': 'Delimiter',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': '<canvas id="game"></canvas>',
  'js': js,
  'manifest': {'actions': [], 'events': []},
});
void main() {
  test(
    'the browser owns missing-parenthesis diagnostics rather than a static scanner',
    () {
      const source =
          'function paint(g){g.addColorStop(.72,"rgba(219,239,235,.04)";}\nconst other=123;';
      final diagnostics = SurfaceProjectValidator.diagnoseForPublicGame(
        project(source),
      ).join('; ');
      expect(diagnostics, isEmpty);
      expect(
        SurfaceProjectValidator.javaScriptLexicalFailureOffset(diagnostics),
        isNull,
      );
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(
          project(source.replaceFirst('.04)";', '.04)");')),
        ),
        isEmpty,
      );
    },
  );
  test('crossed delimiters are diagnosed by the actual browser parser', () {
    const source = 'const state=([1,2)];';
    expect(
      SurfaceProjectValidator.javaScriptLexicalFailureOffset(
        SurfaceProjectValidator.diagnoseForPublicGame(
          project(source),
        ).join('; '),
      ),
      isNull,
    );
  });
  test(
    'strings regexes templates and control blocks preserve valid nesting',
    () {
      const source =
          r'''const xs=[/{\]\)}/,"{)}",`text ${(()=>({a:[1,2]}))().a.length}`];
if(xs.length){for(let i=0;i<xs.length;i++){console.log(xs[i]);}}
''';
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(project(source)),
        isEmpty,
      );
    },
  );
}
