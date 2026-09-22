import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';
import 'package:test/test.dart';

void main() {
  var serial = 0;
  SharedStore open({StoreLimits limits = const StoreLimits()}) =>
      SharedStore.open(
        name: 'keys-test-${DateTime.now().microsecondsSinceEpoch}-${serial++}',
        limits: limits,
      );

  test('sorted immutable keys, literal prefix and deletion', () {
    final store = open();
    try {
      expect(store.keys(), isEmpty);
      for (final key in ['span/z', 'other', 'span/a', 'span/é']) {
        store.commit(checks: {key: null}, changes: {key: Uint8List(0)});
      }
      expect(store.keys(prefix: 'span/'), ['span/a', 'span/z', 'span/é']);
      expect(store.keys(), ['other', 'span/a', 'span/z', 'span/é']);
      expect(() => store.keys().clear(), throwsUnsupportedError);
      final entry = store.read(['span/a'])['span/a']!;
      store.commit(
        checks: {'span/a': entry.revision},
        changes: {'span/a': null},
      );
      expect(store.keys(prefix: 'span/'), ['span/z', 'span/é']);
      expect(() => store.keys(prefix: '\u0000'), throwsArgumentError);
    } finally {
      store.close();
    }
    expect(() => store.keys(), throwsStateError);
  });

  test('limits fail without a partial list', () {
    final store = open(limits: const StoreLimits(maxKeysPerOperation: 2));
    try {
      for (final key in ['a', 'b', 'c']) {
        store.commit(checks: {key: null}, changes: {key: Uint8List(0)});
      }
      expect(() => store.keys(), throwsA(isA<SharedStoreException>()));
      expect(store.keys(prefix: 'a'), ['a']);
    } finally {
      store.close();
    }
  });

  test('concurrent writers can be enumerated', () async {
    final store = open();
    try {
      final name = store.name;
      await Future.wait(
        List.generate(
          4,
          (worker) => Isolate.run(() {
            final peer = SharedStore.open(name: name);
            try {
              for (var i = 0; i < 20; i++) {
                final key = 'span/$worker/$i';
                peer.commit(checks: {key: null}, changes: {key: Uint8List(0)});
              }
            } finally {
              peer.close();
            }
          }),
        ),
      );
      expect(store.keys(prefix: 'span/'), hasLength(80));
    } finally {
      store.close();
    }
  });
}
