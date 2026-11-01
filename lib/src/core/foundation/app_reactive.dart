import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

ProviderContainer _providerContainer = ProviderContainer();

/// The single Riverpod container used by non-widget runtimes and by the root
/// [UncontrolledProviderScope]. Runtime code should prefer constructor
/// injection; this container exists for long-lived services that operate
/// outside the widget tree (Agent runtime, audio, Unity and background work).
ProviderContainer get appProviderContainer => _providerContainer;

void resetAppProviderContainerForTest() {
  final previous = _providerContainer;
  _providerContainer = ProviderContainer();
  previous.dispose();
}

final Object _widgetRefZoneKey = Object();

abstract interface class AppReactiveValue<T> {
  T get value;
  set value(T next);
  Worker listen(
    void Function(T value) listener, {
    bool fireImmediately = false,
  });
  void refresh();
}

class Rx<T> implements AppReactiveValue<T> {
  Rx(T initial)
    : _provider = StateProvider<T>((_) => initial),
      _revisionProvider = StateProvider<int>((_) => 0);

  final StateProvider<T> _provider;
  final StateProvider<int> _revisionProvider;
  T? _pendingValue;
  bool _hasPendingValue = false;
  bool _pendingRefresh = false;
  bool _flushScheduled = false;
  ProviderContainer? _pendingContainer;

  T watch(WidgetRef ref) {
    ref.watch(_revisionProvider);
    return ref.watch(_provider);
  }

  @override
  T get value {
    final ref = Zone.current[_widgetRefZoneKey];
    final current = ref is WidgetRef
        ? watch(ref)
        : appProviderContainer.read(_provider);
    return _hasPendingValue ? _pendingValue as T : current;
  }

  @override
  set value(T next) {
    if (_mustDeferProviderMutation || _flushScheduled) {
      _pendingValue = next;
      _hasPendingValue = true;
      _scheduleFlush();
      return;
    }
    final container = appProviderContainer;
    container.read(_provider.notifier).state = next;
    _bumpRevisionNow(container);
  }

  T call([Object? next = _notProvided]) {
    if (!identical(next, _notProvided)) value = next as T;
    return value;
  }

  @override
  Worker listen(
    void Function(T value) listener, {
    bool fireImmediately = false,
  }) {
    final subscription = appProviderContainer.listen<int>(
      _revisionProvider,
      (_, _) => listener(value),
      fireImmediately: fireImmediately,
    );
    return Worker(subscription.close);
  }

  Stream<T> get stream => Stream<T>.multi((controller) {
    controller.add(value);
    final worker = listen(controller.add);
    controller.onCancel = worker.dispose;
  }, isBroadcast: true);

  @override
  void refresh() => _bumpRevision();

  void trigger(T next) {
    value = next;
  }

  void _bumpRevision() {
    if (_mustDeferProviderMutation || _flushScheduled) {
      _pendingRefresh = true;
      _scheduleFlush();
      return;
    }
    _bumpRevisionNow(appProviderContainer);
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    final container = appProviderContainer;
    _flushScheduled = true;
    _pendingContainer = container;
    scheduleMicrotask(() {
      if (!_flushScheduled || !identical(_pendingContainer, container)) return;
      _flushScheduled = false;
      _pendingContainer = null;
      final hasPendingValue = _hasPendingValue;
      final pendingValue = _pendingValue;
      final needsRefresh = _pendingRefresh;
      _hasPendingValue = false;
      _pendingValue = null;
      _pendingRefresh = false;
      if (!identical(container, appProviderContainer)) return;
      if (hasPendingValue) {
        container.read(_provider.notifier).state = pendingValue as T;
      }
      if (hasPendingValue || needsRefresh) _bumpRevisionNow(container);
    });
  }

  void _bumpRevisionNow(ProviderContainer container) {
    final controller = container.read(_revisionProvider.notifier);
    controller.state++;
  }

  bool get _mustDeferProviderMutation {
    if (Zone.current[_widgetRefZoneKey] is WidgetRef) return true;
    try {
      // Initial attachment and explicit buildScope can build widgets while
      // the scheduler is idle. Riverpod still forbids notifying providers in
      // that scope, even though it is outside a regular draw-frame callback.
      if (WidgetsBinding.instance.buildOwner?.debugBuilding == true) {
        return true;
      }
      return SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks;
    } on Object {
      return false;
    }
  }

  @override
  String toString() => value.toString();
}

const Object _notProvided = Object();

class Rxn<T> extends Rx<T?> {
  Rxn([super.initial]);
}

class RxBool extends Rx<bool> {
  RxBool(super.initial);

  void toggle() => value = !value;
}

class RxString extends Rx<String> {
  RxString(super.initial);
}

class RxInt extends Rx<int> {
  RxInt(super.initial);
}

class RxDouble extends Rx<double> {
  RxDouble(super.initial);
}

class RxnString extends Rxn<String> {
  RxnString([super.initial]);
}

class RxnInt extends Rxn<int> {
  RxnInt([super.initial]);
}

class RxList<E> extends ListBase<E> implements AppReactiveValue<List<E>> {
  RxList([Iterable<E> initial = const []])
    : _signal = Rx<List<E>>([...initial]);

  final Rx<List<E>> _signal;

  @override
  List<E> get value => _signal.value;

  @override
  set value(List<E> next) => _signal.value = [...next];

  @override
  int get length => value.length;

  @override
  set length(int next) {
    final copy = [...value]..length = next;
    value = copy;
  }

  @override
  E operator [](int index) => value[index];

  @override
  void operator []=(int index, E next) {
    final copy = [...value]..[index] = next;
    value = copy;
  }

  @override
  void add(E element) => value = [...value, element];

  @override
  void addAll(Iterable<E> iterable) => value = [...value, ...iterable];

  void assignAll(Iterable<E> iterable) => value = [...iterable];

  void assign(E element) => value = <E>[element];

  @override
  void clear() => value = <E>[];

  @override
  bool remove(Object? element) {
    final copy = [...value];
    final removed = copy.remove(element);
    if (removed) value = copy;
    return removed;
  }

  @override
  E removeAt(int index) {
    final copy = [...value];
    final removed = copy.removeAt(index);
    value = copy;
    return removed;
  }

  @override
  Worker listen(
    void Function(List<E> value) listener, {
    bool fireImmediately = false,
  }) => _signal.listen(listener, fireImmediately: fireImmediately);

  @override
  void refresh() => _signal.refresh();
}

class RxMap<K, V> extends MapBase<K, V> implements AppReactiveValue<Map<K, V>> {
  RxMap([Map<K, V>? initial]) : _signal = Rx<Map<K, V>>({...?initial});

  final Rx<Map<K, V>> _signal;

  @override
  Map<K, V> get value => _signal.value;

  @override
  set value(Map<K, V> next) => _signal.value = {...next};

  @override
  V? operator [](Object? key) => value[key];

  @override
  void operator []=(K key, V next) => value = {...value, key: next};

  @override
  void clear() => value = <K, V>{};

  @override
  Iterable<K> get keys => value.keys;

  @override
  V? remove(Object? key) {
    final copy = {...value};
    final removed = copy.remove(key);
    value = copy;
    return removed;
  }

  void assignAll(Map<K, V> next) => value = next;

  @override
  Worker listen(
    void Function(Map<K, V> value) listener, {
    bool fireImmediately = false,
  }) => _signal.listen(listener, fireImmediately: fireImmediately);

  @override
  void refresh() => _signal.refresh();
}

class RxSet<E> extends SetBase<E> implements AppReactiveValue<Set<E>> {
  RxSet([Iterable<E> initial = const {}]) : _signal = Rx<Set<E>>({...initial});

  final Rx<Set<E>> _signal;

  @override
  Set<E> get value => _signal.value;

  @override
  set value(Set<E> next) => _signal.value = {...next};

  @override
  bool add(E value) {
    final copy = {...this.value};
    final changed = copy.add(value);
    if (changed) this.value = copy;
    return changed;
  }

  @override
  bool contains(Object? element) => value.contains(element);

  @override
  Iterator<E> get iterator => value.iterator;

  @override
  int get length => value.length;

  @override
  E? lookup(Object? element) => value.lookup(element);

  @override
  bool remove(Object? value) {
    final copy = {...this.value};
    final changed = copy.remove(value);
    if (changed) this.value = copy;
    return changed;
  }

  @override
  Set<E> toSet() => {...value};

  void assignAll(Iterable<E> next) => value = {...next};

  @override
  Worker listen(
    void Function(Set<E> value) listener, {
    bool fireImmediately = false,
  }) => _signal.listen(listener, fireImmediately: fireImmediately);

  @override
  void refresh() => _signal.refresh();
}

extension AppRxExtension<T> on T {
  Rx<T> get obs => Rx<T>(this);
}

extension AppRxBoolValueExtension on bool {
  RxBool get obs => RxBool(this);
}

extension AppRxStringValueExtension on String {
  RxString get obs => RxString(this);
}

extension AppRxIntValueExtension on int {
  RxInt get obs => RxInt(this);
}

extension AppRxDoubleValueExtension on double {
  RxDouble get obs => RxDouble(this);
}

extension AppRxListExtension<E> on List<E> {
  RxList<E> get obs => RxList<E>(this);
}

extension AppRxMapExtension<K, V> on Map<K, V> {
  RxMap<K, V> get obs => RxMap<K, V>(this);
}

extension AppRxSetExtension<E> on Set<E> {
  RxSet<E> get obs => RxSet<E>(this);
}

extension AppRxBoolExtension on Rx<bool> {
  void toggle() => value = !value;
}

class Worker {
  Worker(this._dispose);

  final void Function() _dispose;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dispose();
  }

  Future<void> cancel() async => dispose();
}

Worker ever<T>(AppReactiveValue<T> source, void Function(T value) listener) =>
    source.listen(listener);

extension AppIterableLookupExtension<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;

  E? firstWhereOrNull(bool Function(E element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

/// Riverpod-backed replacement for the old implicit reactive builder.
/// Signals read while [builder] runs are watched through the current
/// [WidgetRef], so only those dependencies rebuild this widget.
class AppReactiveBuilder extends StatelessWidget {
  const AppReactiveBuilder(this.builder, {super.key});

  final Widget Function() builder;

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: appProviderContainer,
      child: _ReactiveConsumer(builder),
    );
  }
}

class _ReactiveConsumer extends ConsumerWidget {
  const _ReactiveConsumer(this.builder);

  final Widget Function() builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return runZoned(
      builder,
      zoneValues: <Object, Object>{_widgetRefZoneKey: ref},
    );
  }
}
