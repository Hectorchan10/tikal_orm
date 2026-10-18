part of 'cli.dart';

void _configureEditor(Directory root) {
  final file = File.fromUri(root.uri.resolve('.vscode/tasks.json'));
  if (file.existsSync()) {
    stdout.writeln(
      'Existing .vscode/tasks.json preserved. Add the automatic generation task '
      'from the README if needed.',
    );
    return;
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'version': '2.0.0',
      'tasks': [
        {
          'label': 'TikalORM: generate automatically',
          'type': 'process',
          'command': 'dart',
          'args': ['run', 'tikal_orm:tikal', 'generate', '--watch'],
          'options': {'cwd': r'${workspaceFolder}'},
          'isBackground': true,
          'problemMatcher': <String>[],
          'runOptions': {'runOn': 'folderOpen', 'instanceLimit': 1},
          'presentation': {'reveal': 'silent', 'panel': 'dedicated'},
        },
      ],
    })}\n',
  );
  stdout.writeln(
    'Created .vscode/tasks.json for VS Code/Cursor automatic generation. '
    'Reopen the folder and allow automatic tasks when prompted.',
  );
}
