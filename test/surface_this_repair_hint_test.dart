import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

SurfaceProject _project(String source) => SurfaceProject.fromJson({
  'id': 'this-hint-contract',
  'title': 'Object state',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': '<main id="game">Object state</main>',
  'js': source,
  'manifest': {'actions': [], 'events': []},
});

void main() {
  test('object methods and callback receivers need no ownership proof', () {
    for (final source in [
      'function collision(state,paddle){return state.x>=paddle.x;}'
          'const ball={x:0,y:0,move:function(paddle){'
          'return collision(this,paddle);}};',
      'const ball={step:function(){const alias=this;return alias.x;}};',
      'const ball={step:function(){inspect({...this});}};',
      'function Actor(){this.x=0;}'
          'Actor.prototype.step=function(){this.x+=1;return this.x;};'
          'const actor=new Actor();actor.step();',
      'const owner=window;const root=globalThis;',
      'const object={};Object.setPrototypeOf(object,{});',
      'const ball={step:function(){this.innerHTML="<b>Score</b>";}};',
    ]) {
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_project(source)),
        isEmpty,
        reason: source,
      );
    }
  });

  test('historical restrictions only request current runtime revalidation', () {
    for (final (rule, name) in [
      ('reservedIdentifier', 'this'),
      ('reservedIdentifier', 'window'),
      ('reservedIdentifier', 'top'),
      ('forbiddenMember', 'prototype'),
      ('forbiddenMember', 'innerHTML'),
    ]) {
      final diagnostic =
          '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
          '(rule $rule, name $name, UTF-16 offset 12)';
      final hint = SurfaceProjectValidator.javaScriptRestrictionRepairHint(
        diagnostic,
      );
      expect(
        hint,
        contains('historical webApp scanner policy has been retired'),
      );
      expect(
        hint,
        contains('Revalidate the current project in its Web runtime'),
      );
      expect(
        hint,
        contains('Do not rename bindings, rewrite valid JavaScript'),
      );
      expect(hint, contains('or change gameplay'));
      expect(hint, isNot(contains('failed ownership proof')));
      expect(hint, isNot(contains('consistently rename')));
    }
  });

  test('unrecognized historical evidence cannot inject model repair advice', () {
    for (final diagnostic in [
      'PRIVATE_GENERATED_SOURCE',
      '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
          '(rule forbiddenMember, name PRIVATE_SOURCE, UTF-16 offset 12)',
      '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
          '(rule forbiddenMember, name innerHTML, UTF-16 offset 12) PRIVATE_STACK',
    ]) {
      expect(
        SurfaceProjectValidator.javaScriptRestrictionRepairHint(diagnostic),
        isEmpty,
      );
    }
  });
}
