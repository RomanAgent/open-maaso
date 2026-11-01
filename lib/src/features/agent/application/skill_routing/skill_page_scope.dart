import 'package:maaso/src/app/routing/app_route_catalog.dart';

class SkillPageScope {
  const SkillPageScope._();

  static String? fromRoute(String route) {
    final uri = Uri.tryParse(route.trim());
    if (uri == null) return null;
    for (final destination in AppRouteCatalog.destinations) {
      if (destination.route == uri.path) return destination.id;
    }
    return null;
  }
}
