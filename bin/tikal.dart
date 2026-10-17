// CLI
import 'package:tikal_orm/src/cli/cli.dart' as cli;

export 'package:tikal_orm/src/cli/cli.dart' show run, watchGeneration;

Future<void> main(List<String> arguments) => cli.main(arguments);
