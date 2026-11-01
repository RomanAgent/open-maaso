import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'app_reactive.dart';

abstract class AppLifecycle {
  bool _initialized = false;
  bool _ready = false;
  bool _closed = false;

  bool get isClosed => _closed;

  @mustCallSuper
  void onInit() {}

  @mustCallSuper
  void onReady() {}

  @mustCallSuper
  void onClose() {}

  void initializeLifecycle() {
    if (_initialized) return;
    _initialized = true;
    onInit();
    void markReady() {
      if (_closed || _ready) return;
      _ready = true;
      onReady();
    }

    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => markReady());
    } on FlutterError {
      // Pure Dart-style Flutter tests do not always install a widget binding.
      // Preserve lifecycle ordering without forcing a production binding into
      // the test isolate.
      scheduleMicrotask(markReady);
    }
  }

  void closeLifecycle() {
    if (_closed) return;
    _closed = true;
    onClose();
  }
}

abstract class AppService extends AppLifecycle {}

abstract class AppController extends AppLifecycle {
  /// Kept for controllers that issue an explicit repaint signal. Most Maaso
  /// state is held in Riverpod-backed [Rx] values and does not need this.
  void update([List<Object>? ids, bool condition = true]) {}

  void refresh() {}
}

abstract class AppView<T extends Object> extends StatelessWidget {
  const AppView({super.key});

  T get controller => appServices.find<T>();
}

typedef AppFactory<T extends Object> = T Function();

class _Registration<T extends Object> {
  _Registration.value(
    this.instance, {
    required this.permanent,
    required this.routeScoped,
  }) : factory = null,
       fenix = false,
       scopeReferences = routeScoped ? 1 : 0;

  _Registration.lazy(
    this.factory, {
    required this.fenix,
    required this.permanent,
    required this.routeScoped,
  }) : scopeReferences = routeScoped ? 1 : 0;

  T? instance;
  final AppFactory<T>? factory;
  final bool fenix;
  final bool permanent;
  final bool routeScoped;
  int scopeReferences;
}

/// Riverpod-visible dependency graph for runtimes that cannot receive a
/// WidgetRef. New UI code should watch [appServicesProvider] or a focused
/// provider; background/Unity/audio code may use [appServices] directly.
class AppServices {
  final Map<Type, _Registration<Object>> _registrations = {};
  final List<Set<Type>> _captures = [];
  bool _graphNotificationScheduled = false;
  int _graphNotificationGeneration = 0;

  bool testMode = false;

  T put<T extends Object>(
    T dependency, {
    bool permanent = false,
    bool overrideAbstract = false,
  }) {
    final existing = _registrations[T];
    if (existing != null && !overrideAbstract) {
      final current = existing.instance;
      if (current is T) {
        _captureExisting(T, existing);
        return current;
      }
    }
    final routeScoped = _captures.isNotEmpty;
    _registrations[T] =
        _Registration<T>.value(
              dependency,
              permanent: permanent,
              routeScoped: routeScoped,
            )
            as _Registration<Object>;
    if (_captures.isNotEmpty) _captures.last.add(T);
    _initialize(dependency);
    _notifyGraphChanged();
    return dependency;
  }

  Future<T> putAsync<T extends Object>(
    Future<T> Function() builder, {
    bool permanent = false,
  }) async => put<T>(await builder(), permanent: permanent);

  void lazyPut<T extends Object>(
    AppFactory<T> builder, {
    bool fenix = false,
    bool permanent = false,
  }) {
    final existing = _registrations[T];
    if (existing != null) {
      _captureExisting(T, existing);
      return;
    }
    final routeScoped = _captures.isNotEmpty;
    _registrations[T] =
        _Registration<T>.lazy(
              builder,
              fenix: fenix,
              permanent: permanent,
              routeScoped: routeScoped,
            )
            as _Registration<Object>;
    if (_captures.isNotEmpty) _captures.last.add(T);
    _notifyGraphChanged();
  }

  bool isRegistered<T extends Object>() => _registrations.containsKey(T);

  T find<T extends Object>() {
    final registration = _registrations[T];
    if (registration == null) {
      throw StateError('Service $T is not registered');
    }
    final current = registration.instance;
    if (current is T) return current;
    final factory = registration.factory;
    if (factory == null) {
      throw StateError('Service $T has no instance or factory');
    }
    final created = factory() as T;
    registration.instance = created;
    _initialize(created);
    return created;
  }

  T? maybeFind<T extends Object>() => isRegistered<T>() ? find<T>() : null;

  /// Returns only an already-created instance. Unlike maybeFind, an observer
  /// cannot run a lazy factory or lifecycle initialization through this path.
  T? peek<T extends Object>() {
    final current = _registrations[T]?.instance;
    return current is T ? current : null;
  }

  Future<bool> delete<T extends Object>({bool force = false}) async {
    return deleteByType(T, force: force);
  }

  Future<bool> deleteByType(Type type, {bool force = false}) async {
    final registration = _registrations[type];
    if (registration == null) return false;
    if (registration.permanent && !force) return false;
    _close(registration.instance);
    if (registration.fenix && registration.factory != null) {
      registration.instance = null;
      registration.scopeReferences = 0;
    } else {
      _registrations.remove(type);
    }
    _notifyGraphChanged();
    return true;
  }

  Future<bool> releaseCaptured(Type type) async {
    final registration = _registrations[type];
    if (registration == null || !registration.routeScoped) return false;
    if (registration.scopeReferences > 1) {
      registration.scopeReferences--;
      return true;
    }
    return deleteByType(type);
  }

  Future<void> reset({bool clearFactory = true}) async {
    _graphNotificationGeneration++;
    _graphNotificationScheduled = false;
    for (final registration in _registrations.values.toList().reversed) {
      _close(registration.instance);
    }
    _registrations.clear();
    _captures.clear();
    testMode = false;
    resetAppProviderContainerForTest();
  }

  Set<Type> capture(void Function() register) {
    final owned = <Type>{};
    _captures.add(owned);
    try {
      register();
      return owned;
    } finally {
      _captures.removeLast();
    }
  }

  void _captureExisting(Type type, _Registration<Object> registration) {
    if (_captures.isEmpty || !registration.routeScoped) return;
    if (_captures.last.add(type)) registration.scopeReferences++;
  }

  void _initialize(Object dependency) {
    if (dependency is AppLifecycle) dependency.initializeLifecycle();
  }

  void _close(Object? dependency) {
    if (dependency is AppLifecycle) dependency.closeLifecycle();
  }

  void _notifyGraphChanged() {
    // Route dependencies register their controllers from initState. Riverpod does
    // not allow a watched provider to be synchronously modified while that
    // frame is still building, so coalesce registry invalidations onto the
    // next event-loop turn. Registrations themselves remain synchronous and
    // are therefore available to the route's first build.
    if (_graphNotificationScheduled) return;
    _graphNotificationScheduled = true;
    final generation = _graphNotificationGeneration;
    scheduleMicrotask(() {
      if (generation != _graphNotificationGeneration) return;
      _graphNotificationScheduled = false;
      final revision = appProviderContainer.read(
        appServiceGraphRevisionProvider.notifier,
      );
      revision.state++;
    });
  }
}

final appServices = AppServices();

final appServicesProvider = Provider<AppServices>((ref) {
  ref.watch(appServiceGraphRevisionProvider);
  return appServices;
});

final appServiceGraphRevisionProvider = StateProvider<int>((_) => 0);

abstract class RouteDependencies {
  void dependencies();
}

class RouteDependenciesScope extends StatefulWidget {
  const RouteDependenciesScope({
    super.key,
    required this.dependencies,
    required this.child,
  });

  final RouteDependencies dependencies;
  final Widget child;

  @override
  State<RouteDependenciesScope> createState() => _RouteDependenciesScopeState();
}

class _RouteDependenciesScopeState extends State<RouteDependenciesScope> {
  late final Set<Type> _owned;

  @override
  void initState() {
    super.initState();
    _owned = appServices.capture(widget.dependencies.dependencies);
  }

  @override
  void dispose() {
    for (final type in _owned) {
      _deleteType(type);
    }
    super.dispose();
  }

  void _deleteType(Type type) {
    unawaited(appServices.releaseCaptured(type));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
