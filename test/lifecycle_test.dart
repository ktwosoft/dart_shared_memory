import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';
import 'package:test/test.dart';

void attachedWorker(List<Object> args) {
  final store = SharedStore.open(name: args[0] as String);
  store.commit(
    checks: {'worker': null},
    changes: {
      'worker': Uint8List.fromList([8]),
    },
  );
  (args[1] as SendPort).send('ready');
  // Never holds a native lock outside an operation. The worker can be terminated
  // while Dart runs; NativeFinalizer is only a nondeterministic release backstop.
  while (true) {
    store.read(['worker']);
  }
}

Future<bool> createWorker(String name) => Isolate.run(() {
  final store = SharedStore.open(name: name);
  try {
    return store
        .commit(checks: {'claim': null}, changes: {'claim': Uint8List(0)})
        .committed;
  } finally {
    store.close();
  }
});
void main() {
  test('one winner for competing creation across isolates', () async {
    final anchor = SharedStore.open(name: 'claim');
    try {
      final results = await Future.wait(
        List.generate(8, (_) => createWorker('claim')),
      );
      expect(results.where((v) => v).length, 1);
    } finally {
      anchor.close();
    }
  });
  test('forced worker termination does not strand native locks', () async {
    final anchor = SharedStore.open(name: 'kill');
    final ready = ReceivePort();
    final exited = ReceivePort();
    final worker = await Isolate.spawn(attachedWorker, [
      'kill',
      ready.sendPort,
    ], onExit: exited.sendPort);
    try {
      await ready.first;
      worker.kill(priority: Isolate.immediate);
      await exited.first;
      final s = anchor.read(['worker'])['worker']!;
      expect(
        anchor
            .commit(
              checks: {'worker': s.revision},
              changes: {
                'worker': Uint8List.fromList([9]),
              },
            )
            .committed,
        isTrue,
      );
    } finally {
      worker.kill(priority: Isolate.immediate);
      ready.close();
      exited.close();
      anchor.close();
    }
  });
  test('bounded read output does not alter stored entries', () {
    final store = SharedStore.open(
      name: 'read-limit',
      limits: const StoreLimits(maxOperationBytes: 16),
    );
    try {
      store.commit(checks: {'a': null}, changes: {'a': Uint8List(10)});
      store.commit(checks: {'b': null}, changes: {'b': Uint8List(10)});
      expect(
        () => store.read(['a', 'b']),
        throwsA(isA<SharedStoreException>()),
      );
      expect(store.read(['a'])['a']!.value.length, 10);
    } finally {
      store.close();
    }
  });
  test('store budget includes staged replacements and fails atomically', () {
    final store = SharedStore.open(
      name: 'budget',
      limits: const StoreLimits(
        maxBytes: 4500,
        maxValueBytes: 2000,
        maxOperationBytes: 3000,
      ),
    );
    try {
      final result = store.commit(
        checks: {'a': null},
        changes: {'a': Uint8List(1500)},
      );
      expect(
        () => store.commit(
          checks: {'a': result.revisions['a']},
          changes: {'a': Uint8List(2000)},
        ),
        throwsA(isA<SharedStoreException>()),
      );
      expect(store.read(['a'])['a']!.value.length, 1500);
    } finally {
      store.close();
    }
  });
}
