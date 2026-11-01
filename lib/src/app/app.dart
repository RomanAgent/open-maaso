import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/surface_worker_validation_host.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';

class MaasoApp extends ConsumerWidget {
  const MaasoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServicesProvider);
    final uiControl = appServices.maybeFind<AgentUiControlService>();
    appAgentTakeoverBackButtonDispatcher.bind(uiControl?.coordinator);
    final theme = appServices.maybeFind<ThemeService>();
    if (theme != null) {
      theme.brightness.watch(ref);
      theme.accent.watch(ref);
    }
    final palette =
        theme?.palette ?? AppPalette.of(Brightness.light, AppAccent.blue);

    final localeService = appServices.maybeFind<LocaleConfigService>();
    localeService?.locale.watch(ref);
    final locale =
        localeService?.resolvedFlutterLocale ??
        WidgetsBinding.instance.platformDispatcher.locale;
    AppLocalization.updateLocale(locale);

    return MaterialApp.router(
      title: 'app.title'.tr,
      locale: locale,
      supportedLocales: AppLocalization.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.build(palette),
      routerConfig: appAgentTakeoverRouterConfig(maasoRouter),
      builder: (context, child) {
        final routedChild = child ?? const SizedBox.shrink();
        final appChild = uiControl == null
            ? routedChild
            : AppAgentShell(
                coordinator: uiControl.coordinator,
                child: routedChild,
              );
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const SurfaceWorkerValidationHost(),
            appChild,
            const AppTopNoticeHost(),
          ],
        );
      },
      debugShowCheckedModeBanner: false,
    );
  }
}
