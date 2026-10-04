import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final builder = CBuilder.library(
      name: 'dart_shared_memory',
      assetName: 'src/native_bindings.dart',
      language: Language.cpp,
      std: 'c++17',
      // Native error handling must unwind RAII locks and memory charges.
      flags: [if (input.config.code.targetOS == OS.windows) '/EHsc'],
      sources: ['native/shared_store.cpp'],
      includes: ['native'],
      libraries: [if (input.config.code.targetOS == OS.linux) 'pthread'],
    );

    await builder.run(input: input, output: output);
  });
}
