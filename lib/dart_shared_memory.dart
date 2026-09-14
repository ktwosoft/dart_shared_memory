/// Named binary stores shared by Dart isolates through a native C++17 library.
///
/// Use [SharedStore.open] in each isolate, [SharedStore.read] for copied snapshots,
/// [SharedStore.commit] for atomic conditional batches, and [SharedStore.close]
/// for deterministic release. Values are [EntrySnapshot]s with [EntryRevision]
/// tokens; [StoreLimits] bounds native resource accounting.
///
/// Runtime dependencies: `ffi` and Dart native code assets. Build hooks use
/// `hooks`, `code_assets` and `native_toolchain_c`. No optional backends or
/// internal package dependencies; web and cross-process sharing are unsupported.
library;

export 'src/shared_store.dart';
export 'src/shared_store_exception.dart';
export 'src/shared_store_types.dart';
