import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/capability/capability.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';

Capability _nav(String id, List<String> keywords) => Capability(
  id: id,
  kind: CapabilityKind.navigate,
  title: id,
  description: 'open $id',
  keywords: keywords,
  run: (_) => CapabilityResult.ok('opened $id'),
);

void main() {
  test('register / byId / all / byKind', () {
    final reg = CapabilityRegistry()
      ..registerAll([
        _nav('nav.settings', const ['settings', '设置']),
        _nav('nav.skills', const ['skills', '技能']),
      ]);

    expect(reg.all.length, 2);
    expect(reg.byId('nav.settings')!.title, 'nav.settings');
    expect(reg.byId('missing'), isNull);
    expect(reg.byKind(CapabilityKind.navigate).length, 2);
  });

  test('keyword search matches English and Chinese', () {
    final reg = CapabilityRegistry()
      ..registerAll([
        _nav('nav.settings', const ['settings', 'setting', '设置']),
        _nav('nav.skills', const ['skills', '技能']),
      ]);

    expect(reg.search('open the settings page').first.id, 'nav.settings');
    expect(reg.search('我想看技能').first.id, 'nav.skills');
    expect(reg.search('打开设置').first.id, 'nav.settings');
  });

  test('search returns empty when nothing matches', () {
    final reg = CapabilityRegistry()
      ..register(_nav('nav.settings', const ['设置']));
    expect(reg.search('completely unrelated zzz'), isEmpty);
  });

  test('empty query returns empty list', () {
    final reg = CapabilityRegistry()
      ..register(_nav('nav.settings', const ['settings']));
    expect(reg.search(''), isEmpty);
  });

  test('CapabilityResult factories', () {
    expect(CapabilityResult.ok('hi').ok, isTrue);
    expect(CapabilityResult.error('no').ok, isFalse);
    expect(CapabilityResult.ok('hi').needsConfirm, isFalse);
  });
}
