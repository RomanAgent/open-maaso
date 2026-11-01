import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    appServices.reset();
  });

  testWidgets('dialog and sheet keep ListTile ink above the frost decoration', (
    tester,
  ) async {
    var taps = 0;
    for (final isDialog in [false, true]) {
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [ListTile(title: const Text('Choose'), onTap: () => taps++)],
      );
      await _pumpGlass(
        tester,
        isDialog
            ? AppGlassDialog(child: content)
            : AppGlassSheet(child: content),
        supportsShaderFilters: true,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(taps, 2);
  });

  testWidgets('all backdrops use one frosted pipeline without captures', (
    tester,
  ) async {
    for (final kind in GlassBackdropKind.values) {
      await _pumpGlass(
        tester,
        AppGlassScaffold(
          backdropKind: kind,
          body: const Center(child: AppGlassSurface(child: Text('content'))),
        ),
        supportsShaderFilters: false,
      );
      expect(find.byKey(AppGlassScaffold.frostedPipelineKey), findsOneWidget);
      expect(find.byKey(AppGlassScaffold.livePipelineKey), findsNothing);
      expect(find.byKey(AppGlassScaffold.capturedPipelineKey), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'native surfaces use a visible borderless fallback even with blur requested',
    (tester) async {
      await _pumpGlass(
        tester,
        const AppGlassScaffold(
          backdropKind: GlassBackdropKind.platformView,
          body: Center(
            child: AppGlassSurface(
              role: AppGlassSurfaceRole.field,
              blur: true,
              child: Text('native frost'),
            ),
          ),
        ),
        supportsShaderFilters: true,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(AppGlassScaffold.defaultBackgroundKey), findsNothing);
      final box =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(AppGlassSurface.frostedLayerKey),
                  )
                  .decoration
              as BoxDecoration;
      expect(box.color!.a, greaterThanOrEqualTo(.94));
      expect(box.border, isNull);
      expect(box.gradient, isNull);
    },
  );

  testWidgets('matte cards and scrolling inputs never sample a backdrop', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              AppGlassSurface(blur: true, child: Text('card')),
              AppGlassField(hintText: 'List field', blur: true),
              AppGlassSurface(
                role: AppGlassSurfaceRole.control,
                blur: true,
                child: Text('List capsule'),
              ),
            ],
          ),
        ),
      ),
      supportsShaderFilters: true,
    );
    expect(find.byType(BackdropFilter), findsNothing);
    for (final widget in tester.widgetList<DecoratedBox>(
      find.byKey(AppGlassSurface.frostedLayerKey),
    )) {
      expect((widget.decoration as BoxDecoration).border, isNull);
    }
  });

  testWidgets('explicit fixed input uses one clipped sigma eight region', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: AppGlassField(hintText: 'Search', blur: true),
          ),
        ),
      ),
      supportsShaderFilters: false,
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter.toString(), contains('8.0'));
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(ClipRRect),
      ),
      findsWidgets,
    );
    expect(tester.getSize(find.byType(BackdropFilter)).width, 300);
    expect(tester.getSize(find.byType(BackdropFilter)).height, lessThan(100));
  });

  testWidgets('high contrast and reduced transparency use opaque frost', (
    tester,
  ) async {
    for (final highContrast in [true, false]) {
      await _pumpGlass(
        tester,
        MediaQuery(
          data: MediaQueryData(highContrast: highContrast),
          child: const AppGlassScaffold(
            body: Center(
              child: AppGlassSurface(
                role: AppGlassSurfaceRole.field,
                blur: true,
                child: Text('accessible'),
              ),
            ),
          ),
        ),
        supportsShaderFilters: true,
        forceFrosted: !highContrast,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      final box =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(AppGlassSurface.frostedLayerKey),
                  )
                  .decoration
              as BoxDecoration;
      expect(box.color!.a, 1);
    }
  });

  testWidgets('nested frosted controls share their parent sample', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        body: Center(
          child: AppGlassSurface(
            role: AppGlassSurfaceRole.control,
            blur: true,
            child: AppGlassSurface(
              role: AppGlassSurfaceRole.field,
              blur: true,
              child: Text('nested'),
            ),
          ),
        ),
      ),
      supportsShaderFilters: true,
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('Unity underlay follows iOS runtime readiness without sampling', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final active = appServices.put(ActiveAvatarRuntime());
    final runtime = appServices.put(UnityAvatarRuntime());
    active.register(runtime);
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        backdropKind: GlassBackdropKind.unityUnderlay,
        body: SizedBox.expand(),
      ),
      supportsShaderFilters: true,
    );
    expect(find.byKey(AppGlassScaffold.defaultBackgroundKey), findsOneWidget);
    expect(find.byKey(AppGlassScaffold.unityUnderlayWashKey), findsNothing);
    runtime.isReady.value = true;
    await tester.pump();
    expect(find.byKey(AppGlassScaffold.unityUnderlayWashKey), findsOneWidget);
    expect(find.byKey(AppGlassScaffold.defaultBackgroundKey), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    runtime.isReady.value = false;
    await tester.pump();
    expect(find.byKey(AppGlassScaffold.defaultBackgroundKey), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('scaffold reserves header and footer space for Flutter content', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        appBar: SizedBox(key: Key('header'), height: 64),
        bottomNavigationBar: SizedBox(key: Key('footer'), height: 56),
        body: SizedBox.expand(key: Key('content')),
      ),
      supportsShaderFilters: true,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('content'))).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byKey(const Key('header'))).dy,
      ),
    );
    expect(
      tester.getBottomLeft(find.byKey(const Key('content'))).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('footer'))).dy),
    );
    final background = tester.widget<ColoredBox>(
      find.byKey(AppGlassScaffold.defaultBackgroundKey),
    );
    expect(background.color, const Color(0xFFFFFFFF));
  });

  testWidgets('scaffold provides Material for dropdown controls', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      AppGlassScaffold(
        body: Center(
          child: DropdownButton<String>(
            value: 'system',
            items: const [
              DropdownMenuItem(value: 'system', child: Text('System')),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
      supportsShaderFilters: true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass buttons keep a 48 point target and invoke callbacks', (
    tester,
  ) async {
    var presses = 0;
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassButton(label: 'Continue', onPressed: () => presses += 1),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    final size = tester.getSize(find.byType(AppGlassButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(presses, 1);
  });

  testWidgets('icon button exposes label and stays disabled without callback', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const Center(
        child: AppGlassIconButton(
          icon: Icons.close,
          tooltip: 'Close panel',
          onPressed: null,
        ),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    expect(find.bySemanticsLabel('Close panel'), findsOneWidget);
    final size = tester.getSize(find.byType(AppGlassIconButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('native underlay icon button uses the visible glass recipe', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        body: Center(
          child: AppGlassIconButton(
            icon: Icons.more_horiz_rounded,
            tooltip: 'More',
            onPressed: null,
          ),
        ),
      ),
      supportsShaderFilters: true,
    );

    final box =
        tester
                .widget<DecoratedBox>(
                  find.byKey(AppGlassSurface.frostedLayerKey),
                )
                .decoration
            as BoxDecoration;
    expect(box.color!.a, greaterThanOrEqualTo(.94));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('glass page header exposes a 48 point Back action', (
    tester,
  ) async {
    var backPresses = 0;
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassPageHeader(
          title: 'Settings',
          onBack: () => backPresses += 1,
          trailing: const Text('Refreshing'),
        ),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Refreshing'), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    final size = tester.getSize(find.byType(AppGlassBackButton));
    expect(size.width, 48);
    expect(size.height, 48);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pump();
    expect(backPresses, 1);
  });

  testWidgets('glass field forwards text input behavior', (tester) async {
    final controller = TextEditingController(text: 'hello');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await _pumpGlass(
      tester,
      AppGlassField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.emailAddress,
        obscureText: true,
        textInputAction: TextInputAction.done,
      ),
      supportsShaderFilters: true,
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller, same(controller));
    expect(field.focusNode, same(focusNode));
    expect(field.keyboardType, TextInputType.emailAddress);
    expect(field.obscureText, isTrue);
    expect(field.textInputAction, TextInputAction.done);
  });

  testWidgets('native underlay field uses the shared visible glass shell', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        body: Center(child: AppGlassField(hintText: 'Name', blur: true)),
      ),
      supportsShaderFilters: true,
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(AppGlassSurface), findsOneWidget);
    final box =
        tester
                .widget<DecoratedBox>(
                  find.byKey(AppGlassSurface.frostedLayerKey),
                )
                .decoration
            as BoxDecoration;
    expect(box.color!.a, greaterThanOrEqualTo(.94));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('native underlay chip uses the shared visible glass shell', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        body: Center(child: AppGlassChip(label: 'Balanced')),
      ),
      supportsShaderFilters: true,
    );

    expect(find.byType(AppGlassSurface), findsOneWidget);
  });

  testWidgets('glass app bar owns one continuous surface', (tester) async {
    await _pumpGlass(
      tester,
      const AppGlassAppBar(
        title: 'Settings',
        leading: Icon(Icons.chevron_left),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    final surfaces = find.descendant(
      of: find.byType(AppGlassAppBar),
      matching: find.byType(AppGlassSurface),
    );
    expect(surfaces, findsOneWidget);
  });

  testWidgets('composer keeps field actions and footer in one glass shell', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassComposer(
        leading: Icon(Icons.add, key: ValueKey<String>('leading')),
        field: Text('field', key: ValueKey<String>('field')),
        trailing: Icon(Icons.send, key: ValueKey<String>('trailing')),
        footer: Text('footer', key: ValueKey<String>('footer')),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    final surfaces = find.descendant(
      of: find.byType(AppGlassComposer),
      matching: find.byType(AppGlassSurface),
    );
    expect(surfaces, findsOneWidget);
    expect(find.byKey(const ValueKey<String>('leading')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('field')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('trailing')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('footer')), findsOneWidget);
  });

  testWidgets('glass dialog and sheet helpers render transient surfaces', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: <Widget>[
              TextButton(
                onPressed: () => showAppGlassDialog<void>(
                  context: context,
                  builder: (_) => const Text('Dialog content'),
                ),
                child: const Text('Open dialog'),
              ),
              TextButton(
                onPressed: () => showAppGlassSheet<void>(
                  context: context,
                  builder: (_) => const Text('Sheet content'),
                ),
                child: const Text('Open sheet'),
              ),
            ],
          ),
        ),
      ),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    expect(find.byType(AppGlassDialog), findsOneWidget);
    expect(find.text('Dialog content'), findsOneWidget);
    Navigator.of(tester.element(find.byType(AppGlassDialog))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    expect(find.byType(AppGlassSheet), findsOneWidget);
    expect(find.text('Sheet content'), findsOneWidget);
  });

  testWidgets('glass notice exposes a live-region semantic label', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      const AppGlassNotice(title: 'Saved', message: 'Profile updated'),
      supportsShaderFilters: true,
      forceFrosted: true,
    );

    expect(find.bySemanticsLabel('Saved. Profile updated'), findsOneWidget);
  });

  testWidgets('glass toggle forwards state and exposes semantics', (
    tester,
  ) async {
    bool? changed;
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassToggle(
          value: false,
          semanticLabel: 'Cloud brain',
          onChanged: (value) => changed = value,
        ),
      ),
      supportsShaderFilters: true,
    );

    expect(find.bySemanticsLabel('Cloud brain'), findsOneWidget);
    await tester.tap(find.byType(AppGlassToggle));
    await tester.pump();
    expect(changed, isTrue);
  });

  testWidgets('glass toggle exposes a semantic tap action', (tester) async {
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassToggle(
          value: false,
          semanticLabel: 'Cloud brain',
          onChanged: (_) {},
        ),
      ),
      supportsShaderFilters: true,
    );

    final data = tester
        .getSemantics(find.byType(AppGlassToggle))
        .getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  });

  testWidgets('platform-view glass toggle keeps a visible glass shell', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        body: Center(child: AppGlassToggle(value: false, onChanged: (_) {})),
      ),
      supportsShaderFilters: true,
    );

    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('disabled glass toggle remains inert', (tester) async {
    await _pumpGlass(
      tester,
      const Center(
        child: AppGlassToggle(
          value: false,
          semanticLabel: 'Disabled toggle',
          onChanged: null,
        ),
      ),
      supportsShaderFilters: true,
    );

    final node = tester.getSemantics(find.bySemanticsLabel('Disabled toggle'));
    expect(
      node.getSemanticsData().flagsCollection.isEnabled,
      ui.Tristate.isFalse,
    );
    final size = tester.getSize(find.byType(AppGlassToggle));
    expect(size.height, greaterThanOrEqualTo(MaasoGlassTheme.controlTarget));
  });

  testWidgets('reduced-motion glass toggle keeps a 48 point hit target', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Center(child: AppGlassToggle(value: false, onChanged: (_) {})),
      ),
      supportsShaderFilters: true,
    );

    final size = tester.getSize(find.byType(AppGlassToggle));
    expect(size.height, greaterThanOrEqualTo(MaasoGlassTheme.controlTarget));
  });

  testWidgets('glass slider enforces a 48 point minimum width', (tester) async {
    await _pumpGlass(
      tester,
      Center(child: AppGlassSlider(value: 0.5, width: 32, onChanged: (_) {})),
      supportsShaderFilters: true,
    );

    final size = tester.getSize(find.byType(AppGlassSlider));
    expect(size.width, greaterThanOrEqualTo(MaasoGlassTheme.controlTarget));
  });

  testWidgets('glass slider exposes semantic increase and decrease actions', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassSlider(
          value: 50,
          min: 0,
          max: 100,
          semanticLabel: 'Intensity',
          onChanged: (_) {},
        ),
      ),
      supportsShaderFilters: true,
    );

    final data = tester
        .getSemantics(find.byType(AppGlassSlider))
        .getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    expect(data.increasedValue, '60.00');
    expect(data.decreasedValue, '40.00');
  });

  testWidgets('platform-view glass slider keeps a visible glass shell', (
    tester,
  ) async {
    await _pumpGlass(
      tester,
      AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        body: Center(child: AppGlassSlider(value: 0.5, onChanged: (_) {})),
      ),
      supportsShaderFilters: true,
    );

    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('glass slider keeps values in the public range', (tester) async {
    double? changed;
    await _pumpGlass(
      tester,
      Center(
        child: AppGlassSlider(
          value: 15,
          min: 10,
          max: 20,
          semanticLabel: 'Intensity',
          onChanged: (value) => changed = value,
        ),
      ),
      supportsShaderFilters: true,
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 15);
    slider.onChanged!(17.5);
    expect(changed, 17.5);
  });
}

Future<void> _pumpGlass(
  WidgetTester tester,
  Widget child, {
  required bool supportsShaderFilters,
  bool forceFrosted = false,
}) async {
  appServices.put(
    GlassUiService(
      supportsShaderFilters: () => supportsShaderFilters,
      forceFrosted: forceFrosted,
    ),
  );
  appServices.find<GlassUiService>().forceFrosted.value = forceFrosted;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
      home: child,
    ),
  );
  await tester.pump();
}
