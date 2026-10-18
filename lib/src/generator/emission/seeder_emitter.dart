part of '../analysis/seeder_analyzer.dart';

String _emitSeeders(List<AnalyzedSeeder> seeders, Map<String, String> aliases) {
  final byId = {for (final seeder in seeders) seeder.id: seeder};
  final code = StringBuffer(
    '/// Statically discovered seeder callbacks.\nfinal orm.SeederRegistry tikalSeeders = orm.SeederRegistry({\n',
  );
  String literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
  for (final seeder in seeders) {
    code.writeln('${literal(seeder.name)}: () async {');
    for (final dependency in seeder.calls) {
      code.writeln(
        'await tikalSeeders.run(className: ${literal(byId[dependency]!.name)});',
      );
    }
    if (seeder.hasRun) {
      code.writeln(
        'await ${aliases[seeder.path]}.${seeder.name}${seeder.constructor}().run();',
      );
    }
    code.writeln('},');
  }
  code.writeln('});');
  return code.toString();
}
