import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';

Future<void> worker(String name) => Isolate.run(() {
  final store = SharedStore.open(name: name);
  try {
    for (var i = 0; i < 100; i++) {
      while (true) {
        final old = store.read(['counter'])['counter']!;
        final next = Uint8List(8);
        ByteData.sublistView(
          next,
        ).setInt64(0, ByteData.sublistView(old.value).getInt64(0) + 1);
        if (store
            .commit(
              checks: {'counter': old.revision},
              changes: {'counter': next},
            )
            .committed) {
          break;
        }
      }
    }
  } finally {
    store.close();
  }
});

Future<void> main() async {
  // This anchor retains the context across worker attachment/detachment.
  final store = SharedStore.open(name: 'example');
  try {
    store.commit(checks: {'counter': null}, changes: {'counter': Uint8List(8)});
    await Future.wait(List.generate(4, (_) => worker('example')));
    final total = ByteData.sublistView(
      store.read(['counter'])['counter']!.value,
    ).getInt64(0);
    if (total != 400) throw StateError('Expected 400, got $total');
    print('Four isolates shared one native store: counter=$total');
  } finally {
    store.close();
  }
}
