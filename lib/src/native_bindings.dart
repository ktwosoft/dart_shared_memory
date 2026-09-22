// Internal C ABI declarations; not exported as Dart API.
// ignore_for_file: public_member_api_docs

@DefaultAsset('package:dart_shared_memory/src/native_bindings.dart')
library;

import 'dart:ffi';

final class NativeLimits extends Struct {
  @Int64()
  external int maxBytes;
  @Int64()
  external int maxEntries;
  @Int64()
  external int maxValue;
  @Int64()
  external int maxKeys;
  @Int64()
  external int maxKey;
  @Int64()
  external int maxOperation;
}

final class NativeInput extends Struct {
  external Pointer<Uint8> key;
  @Int64()
  external int keySize;
  external Pointer<Uint8> value;
  @Int64()
  external int valueSize;
  @Int64()
  external int context;
  @Int64()
  external int revision;
  @Int64()
  external int action;
}

final class NativeValue extends Struct {
  external Pointer<Uint8> value;
  @Int64()
  external int size;
  @Int64()
  external int context;
  @Int64()
  external int revision;
}

final class NativeResult extends Struct {
  @Int64()
  external int count;
  external Pointer<NativeValue> values;
}

final class NativeKey extends Struct {
  external Pointer<Uint8> key;
  @Int64()
  external int size;
}

final class NativeKeysResult extends Struct {
  @Int64()
  external int count;
  external Pointer<NativeKey> keys;
}

@Native<Int32 Function()>(symbol: 'ss_abi_version')
external int abiVersion();
@Native<
  Int32 Function(
    Pointer<Uint8>,
    Int64,
    Pointer<NativeLimits>,
    Pointer<Pointer<Void>>,
  )
>(symbol: 'ss_open')
external int openStore(
  Pointer<Uint8> name,
  int size,
  Pointer<NativeLimits> limits,
  Pointer<Pointer<Void>> output,
);
@Native<Void Function(Pointer<Void>)>(symbol: 'ss_close')
external void closeStore(Pointer<Void> handle);
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<NativeInput>,
    Int64,
    Pointer<Pointer<NativeResult>>,
  )
>(symbol: 'ss_read')
external int readStore(
  Pointer<Void> handle,
  Pointer<NativeInput> inputs,
  int count,
  Pointer<Pointer<NativeResult>> output,
);
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<NativeInput>,
    Int64,
    Pointer<Pointer<NativeResult>>,
  )
>(symbol: 'ss_commit')
external int commitStore(
  Pointer<Void> handle,
  Pointer<NativeInput> inputs,
  int count,
  Pointer<Pointer<NativeResult>> output,
);
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Pointer<NativeKeysResult>>,
  )
>(symbol: 'ss_keys')
external int keysStore(
  Pointer<Void> handle,
  Pointer<Uint8> prefix,
  int prefixSize,
  Pointer<Pointer<NativeKeysResult>> output,
);
@Native<Void Function(Pointer<NativeKeysResult>)>(symbol: 'ss_keys_result_free')
external void freeKeysResult(Pointer<NativeKeysResult> output);
@Native<Void Function(Pointer<NativeResult>)>(symbol: 'ss_result_free')
external void freeResult(Pointer<NativeResult> output);
