import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

void main() {
  test(
    'callback identity and receivers are authored browser code, not a repair policy',
    () {
      for (final source in [
        'class Input{constructor(){this.listener=this.onKeyDown.bind(this);}'
            'onKeyDown(event){this.key=event.key;}}',
        'class Input{constructor(){const owner=this;'
            'this.listener=(event)=>owner.onKeyDown(event);}}',
        'const owner=window;',
        'Input.prototype.onKeyDown=function(event){};',
      ]) {
        final project = SurfaceProject.fromJson({
          'id': 'callback-browser-contract',
          'title': 'Input callbacks',
          'kind': 'fullscreen',
          'rendering': 'webApp',
          'experienceType': 'game',
          'html': '<canvas id="game"></canvas>',
          'js': source,
          'manifest': {'actions': [], 'events': []},
        });
        final issues = SurfaceProjectValidator.diagnoseForPublicGame(project);
        expect(issues, isEmpty, reason: source);
        expect(
          SurfaceProjectValidator.javaScriptRestrictionRepairHint(
            issues.join('; '),
          ),
          isEmpty,
        );
      }
    },
  );
}
