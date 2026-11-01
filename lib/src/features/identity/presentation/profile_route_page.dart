import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import '../../economy/application/store_purchase_service.dart';
import '../application/companion_profile_service.dart';
import '../application/identity_service.dart';
import '../application/profile_controller.dart';
import 'profile_page.dart';

class ProfileRoutePage extends StatefulWidget {
  const ProfileRoutePage({
    super.key,
    required this.route,
    required this.membershipRoute,
  });
  final String route, membershipRoute;
  @override
  State<ProfileRoutePage> createState() => _ProfileRoutePageState();
}

class _ProfileRoutePageState extends State<ProfileRoutePage> {
  ProfileController? _controller;
  @override
  void initState() {
    super.initState();
    final identity = appServices.maybeFind<IdentityService>();
    final companion = appServices.maybeFind<CompanionProfileService>();
    if (identity != null && companion != null) {
      _controller = ProfileController(identity: identity, companion: companion);
    }
  }

  @override
  void dispose() {
    _controller?.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller case final controller?) {
      return ProfilePage(
        controller: controller,
        route: widget.route,
        membershipRoute: widget.membershipRoute,
        membership: appServices.maybeFind<StorePurchaseService>(),
      );
    }
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: zh ? '个人信息' : 'My profile',
        onBack: () => appNavigation.pop(),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            zh
                ? '个人资料暂不可用，请重新登录后打开。'
                : 'Your profile is unavailable. Sign in and reopen this page.',
          ),
        ),
      ),
    );
  }
}
