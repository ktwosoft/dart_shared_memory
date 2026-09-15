# dart_shared_memory

Share named maps of string keys and binary values between Dart isolates using
native memory. Each isolate opens its own handle to the same store. Reads return
copied snapshots; conditional commits change multiple entries atomically.

The API has four operations: **open, read, commit, close**. Calls are synchronous.
The C++17 implementation owns storage and locks; Dart owns encoding and application
logic. No coordinator isolate or external service is required.

## Installation

```sh
dart pub add dart_shared_memory
```

Requires Dart 3.12 or later and a C++17 compiler. Dart build hooks compile the
native library automatically. On macOS, install Xcode Command Line Tools with
`xcode-select --install` if they are not already installed.

The build hook uses `code_assets` 1.x so Flutter applications can resolve it
alongside `objective_c` and other native packages that require that major
version.

Version 0.1.0 has been tested on **macOS arm64**, including an AOT CLI bundle.
Other native platforms need toolchain and runtime validation. Web is unsupported.

## Quick start

```dart
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';

void main() {
  final store = SharedStore.open(name: 'example');
  final key = 'counter';
  try {
    final created = store.commit(
      checks: {key: null}, // Create only if absent.
      changes: {key: Uint8List(8)},
    );
    if (!created.committed) throw StateError('Counter already exists');

    final snapshot = store.read([key])[key]!;
    final bytes = snapshot.value; // A mutable, Dart-owned copy.
    ByteData.sublistView(bytes).setInt64(0, 42);
    final result = store.commit(
      checks: {key: snapshot.revision},
      changes: {key: bytes},
    );
    print('Updated: ${result.committed}');
  } finally {
    store.close();
  }
}
```

Run the [complete example](example/dart_shared_memory_example.dart) or the
[four-isolate counter](example/multi_isolate.dart):

```sh
dart run example/dart_shared_memory_example.dart
dart run example/multi_isolate.dart
```

## Sharing across isolates

Pass the store **name** to workers and call `SharedStore.open` inside each worker.
Use identical `StoreLimits` on every handle. The wrapper and native pointers must
not be sent between isolates. Keep one anchor handle open while workers start,
stop, or restart. Closing the last handle destroys all stored data; reopening the
same name creates a fresh, empty context.

On a commit conflict, read again and recompute the change. The multi-isolate
example demonstrates this loop. Applications choose their own retry limit and
backoff; calculations that may repeat should not perform external side effects.

## Reads and atomic commits

| Operation | Contract |
|---|---|
| `SharedStore.open(name:, limits:)` | Create or attach to a named native context. Existing limits must match. |
| `read(keys)` | One consistent snapshot of selected keys, in input order. Missing keys map to null. |
| `commit(checks:, changes:)` | Validate all preconditions, then apply all changes or none. |
| `close()` | Release this handle; idempotent. The last close destroys the context. |

Single-entry operations use batches of one. A read rejects duplicate keys and
accepts an empty batch. A commit requires at least one change.

| Check | Change | Meaning |
|---|---|---|
| `null` | Bytes | Create only if absent |
| Existing revision | Bytes | Replace only that revision |
| Existing revision | `null` | Delete only that revision |
| Absence or revision | Key omitted | Check without changing |

Every changed key requires a check. An empty byte array is a stored value,
not deletion. Additional read-only checks can guard a transaction involving
other entries. Include all related keys in one read and one commit to coordinate
multi-entry changes. Separate read calls do not form a joint snapshot.

`CommitResult.committed == false` means a conflict and no applied changes.
On success, `revisions` contains changed keys only, with null for deletions.
Revisions reject stale updates after entry or store recreation and never wrap.
An absence check means absent **at commit time**, not “never existed.”

Names and keys are case-sensitive valid Unicode, encoded as UTF-8. Empty text,
NUL and malformed Unicode are rejected. No normalization or path interpretation
is performed: `a/b` is an ordinary key. Transactions stay within one named store.

## Resource limits and errors

| `StoreLimits` field | Default |
|---|---:|
| `maxBytes` | 64 MiB |
| `maxEntries` | 100,000 |
| `maxValueBytes` | 8 MiB |
| `maxKeysPerOperation` | 1,024 |
| `maxKeyBytes` | 1,024 UTF-8 bytes |
| `maxOperationBytes` | 16 MiB |

Names have a separate 4,096-byte limit. Native accounting includes live and staged
values, pinned buffers, results and metadata allowances. Reads and replacements
need spare capacity. Dart copies and allocator overhead are additional, so this
is not an exact process memory bound. Reads retain immutable native buffers while capturing a snapshot, then copy
the bytes into Dart-owned memory. Locks stay inside native calls.

Invalid Dart inputs throw `ArgumentError`; a closed handle throws `StateError`.
Native failures throw `SharedStoreException` with a `SharedStoreError` category,
including capacity, configuration, allocation and ABI failures. A commit may run
out of staging capacity before it discovers a conflict.

Native failures before publication apply no changes. If a successful result
cannot reach Dart—for example, because the isolate terminates after committing—
the mutation may already have happened. Re-read after an uncertain outcome.

## Execution and deployment

Lock waits, byte copies and cleanup block the calling isolate. Wrapping a call in
a `Future` does not offload it. Use bounded payloads and measure latency for your
workload; native lock fairness and a maximum wait time are not guaranteed.

```sh
dart build cli --target example/multi_isolate.dart --output dist
```

Ship the entire generated bundle, including its native library. All isolates
must use the same loaded code asset. There is no manual library-path override.

The store is volatile and process-local. It does not share memory between
processes, persist data, emit notifications, or atomically coordinate a database
transaction or external side effect.

## Running Tests

```sh
dart test
dart analyze
```

The standalone native concurrency tests can also be run with a C++17 compiler:

```sh
clang++ -std=c++17 -O1 -g -pthread native/test/store_test.cpp -o /tmp/shared_store_test
/tmp/shared_store_test
```

## License

Apache-2.0. See [LICENSE](LICENSE).
