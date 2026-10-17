import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

// Database
import 'package:tikal_orm/tikal_orm.dart';

// Generator
import 'package:tikal_orm/src/generator/model_analyzer.dart';
import 'package:tikal_orm/src/generator/seeder_analyzer.dart';

part 'watch.dart';
part 'seeders.dart';
part 'commands.dart';
part 'generation.dart';
part 'configuration.dart';

Future<void> main(List<String> arguments) async {
  try {
    await run(arguments);
  } on TikalException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } on FormatException catch (e) {
    stderr.writeln('Invalid model or configuration: ${e.message}');
    exitCode = 1;
  } on FileSystemException catch (e) {
    stderr.writeln('File error: ${e.message} (${e.path})');
    exitCode = 1;
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
