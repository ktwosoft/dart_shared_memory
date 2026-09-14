import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';
import 'package:test/test.dart';

Uint8List bytes(int n) => Uint8List.fromList([n]);
void main() {
  var id = 0;
  late SharedStore store;
  setUp(() => store = SharedStore.open(name: 'test-${id++}'));
  tearDown(() => store.close());
  test(
    'empty values, missing entries, conditional write, copied snapshots',
    () {
      expect(store.read(['a']), {'a': null});
      final input = bytes(7);
      expect(
        store
            .commit(
              checks: {'a': null, 'b': null},
              changes: {'a': input, 'b': Uint8List(0)},
            )
            .committed,
        isTrue,
      );
      input[0] = 9;
      final s = store.read(['a', 'b']);
      expect(s['a']!.value, [7]);
      expect(s['b']!.value, isEmpty);
      s['a']!.value[0] = 10;
      expect(store.read(['a'])['a']!.value, [7]);
      expect(
        store.commit(checks: {'a': null}, changes: {'a': bytes(2)}).committed,
        isFalse,
      );
    },
  );
  test('atomic conflict, read-only checks, deletion and ABA', () {
    store.commit(
      checks: {'a': null, 'b': null},
      changes: {'a': bytes(1), 'b': bytes(2)},
    );
    final s = store.read(['a', 'b']);
    store.commit(checks: {'a': s['a']!.revision}, changes: {'a': null});
    store.commit(checks: {'a': null}, changes: {'a': bytes(3)});
    final r = store.commit(
      checks: {'a': s['a']!.revision, 'b': s['b']!.revision},
      changes: {'b': bytes(9)},
    );
    expect(r.committed, isFalse);
    expect(store.read(['b'])['b']!.value, [2]);
  });
  test('same names attach and configuration mismatch fails', () {
    final other = SharedStore.open(name: store.name);
    try {
      store.commit(checks: {'x': null}, changes: {'x': bytes(4)});
      expect(other.read(['x'])['x']!.value, [4]);
      expect(
        () => SharedStore.open(
          name: store.name,
          limits: const StoreLimits(maxEntries: 2),
        ),
        throwsA(isA<SharedStoreException>()),
      );
    } finally {
      other.close();
    }
  });
  test('last close recreates context and invalidates old revision', () {
    final s = SharedStore.open(name: 'recreate');
    final rev = s
        .commit(checks: {'x': null}, changes: {'x': bytes(1)})
        .revisions['x']!;
    s.close();
    s.close();
    expect(() => s.read(['x']), throwsStateError);
    final t = SharedStore.open(name: 'recreate');
    try {
      t.commit(checks: {'x': null}, changes: {'x': bytes(2)});
      expect(
        t.commit(checks: {'x': rev}, changes: {'x': bytes(3)}).committed,
        isFalse,
      );
    } finally {
      t.close();
    }
  });
  test('reject invalid batches and text', () {
    expect(() => store.read(['a', 'a']), throwsArgumentError);
    expect(() => store.read(['']), throwsArgumentError);
    expect(() => store.read(['a\u0000']), throwsArgumentError);
    expect(
      () => store.read([String.fromCharCode(0xd800)]),
      throwsArgumentError,
    );
    expect(
      () => store.commit(checks: {}, changes: {'a': bytes(1)}),
      throwsArgumentError,
    );
    expect(
      () => store.commit(checks: {'a': null}, changes: {'a': null}),
      throwsArgumentError,
    );
  });
  test('limits reject entire batch', () {
    final t = SharedStore.open(
      name: 'limits',
      limits: const StoreLimits(maxEntries: 1, maxValueBytes: 2),
    );
    try {
      expect(
        () => t.commit(
          checks: {'a': null, 'b': null},
          changes: {'a': bytes(1), 'b': bytes(2)},
        ),
        throwsA(isA<SharedStoreException>()),
      );
      expect(t.read(['a', 'b']).values, everyElement(isNull));
      expect(
        () => t.commit(checks: {'a': null}, changes: {'a': Uint8List(3)}),
        throwsArgumentError,
      );
    } finally {
      t.close();
    }
  });
  test(
    'real isolates increment and preserve paired snapshot invariants',
    () async {
      store.commit(
        checks: {'a': null, 'b': null},
        changes: {'a': Uint8List(8), 'b': Uint8List(8)},
      );
      final name = store.name;
      await Future.wait(List.generate(4, (_) => incrementWorker(name)));
      expect(
        ByteData.sublistView(store.read(['a'])['a']!.value).getInt64(0),
        400,
      );
    },
  );
}

Future<void> incrementWorker(String name) => Isolate.run(() {
  final t = SharedStore.open(name: name);
  try {
    for (var i = 0; i < 100; i++) {
      while (true) {
        final s = t.read(['a', 'b']);
        final a = ByteData.sublistView(s['a']!.value).getInt64(0);
        final b = ByteData.sublistView(s['b']!.value).getInt64(0);
        if (a != b) throw StateError('torn snapshot');
        final next = Uint8List(8);
        ByteData.sublistView(next).setInt64(0, a + 1);
        if (t
            .commit(
              checks: {'a': s['a']!.revision, 'b': s['b']!.revision},
              changes: {'a': next, 'b': next},
            )
            .committed) {
          break;
        }
      }
    }
  } finally {
    t.close();
  }
});
