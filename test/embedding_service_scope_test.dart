import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/embedding_service.dart';

void main() {
  test(
    'full text keys do not alias inputs sharing their first 512 characters',
    () async {
      final backend = _Backend();
      final service = EmbeddingService(
        backend: backend,
        contextKey: () => 'account-a',
      );
      final prefix = 'x' * 512;
      expect(await service.embed('${prefix}first'), [1.0, 0.0]);
      expect(await service.embed('${prefix}second'), [2.0, 0.0]);
      expect(backend.calls, 2);
      expect(await service.embed('${prefix}first'), [1.0, 0.0]);
      expect(backend.calls, 2);
    },
  );

  test(
    'account and provider context changes cannot reuse an older vector',
    () async {
      final backend = _Backend();
      var context = 'account-a|provider-one';
      final service = EmbeddingService(
        backend: backend,
        contextKey: () => context,
      );
      expect(await service.embed('same words'), [1.0, 0.0]);
      context = 'account-b|provider-one';
      expect(await service.embed('same words'), [2.0, 0.0]);
      context = 'account-b|provider-two';
      expect(await service.embed('same words'), [3.0, 0.0]);
      expect(backend.calls, 3);
    },
  );

  test(
    'late previous-scope result cannot be returned or cached in a new scope',
    () async {
      final pending = Completer<List<double>?>();
      final backend = _Backend()..pending = pending;
      var context = 'account-a-generation-1';
      final service = EmbeddingService(
        backend: backend,
        contextKey: () => context,
      );
      final old = service.embed('same words');
      context = 'account-b-generation-3';
      backend.pending = null;
      expect(await service.embed('same words'), [2.0, 0.0]);
      pending.complete([1, 0]);
      expect(await old, isNull);
      expect(await service.embed('same words'), [2.0, 0.0]);
      expect(backend.calls, 2);
    },
  );

  test(
    'unmounted or unavailable provider returns fallback without a request',
    () async {
      final backend = _Backend();
      Object? context;
      final service = EmbeddingService(
        backend: backend,
        contextKey: () => context,
      );
      expect(service.isAvailable, isFalse);
      expect(await service.embed('same words'), isNull);
      context = 'account-a';
      backend.available = false;
      expect(service.isAvailable, isFalse);
      expect(await service.embed('same words'), isNull);
      expect(backend.calls, 0);
    },
  );

  test('null provider results are not permanently cached', () async {
    final backend = _Backend()..nullResult = true;
    final service = EmbeddingService(
      backend: backend,
      contextKey: () => 'account-a',
    );
    expect(await service.embed('same words'), isNull);
    backend.nullResult = false;
    expect(await service.embed('same words'), [2.0, 0.0]);
    expect(backend.calls, 2);
  });
}

class _Backend extends EmbeddingBackend {
  int calls = 0;
  bool available = true;
  bool nullResult = false;
  Completer<List<double>?>? pending;
  @override
  bool get isAvailable => available;
  @override
  Future<List<double>?> embed(String text) async {
    calls++;
    if (pending != null) return pending!.future;
    if (nullResult) return null;
    return [calls.toDouble(), 0];
  }
}
