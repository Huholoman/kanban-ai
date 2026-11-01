import 'package:backlog_core/backlog_core.dart' show DoctorLevel, DoctorSection, runDoctor;
import 'package:dart_tui/dart_tui.dart' show Cmd, KeyMsg, Msg;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Global › Doctor*: the findings of [runDoctor]; `r` looks again.
final class DoctorScreen extends TextScreen {
  DoctorScreen(this.locations, this.sections) : super('Doctor', () => const []);

  final ConfigLocations locations;
  List<DoctorSection> sections;

  /// Runs the doctor in the background, then [apply]s the findings.
  static Cmd run(ConfigLocations locations, void Function(Navigator navigator, List<DoctorSection> sections) apply) =>
      Navigator.task(() async {
        final sections = await runDoctor(
          environment: locations.environment,
          registryFile: locations.registryFile,
          serverFile: locations.serverFile,
        );
        return (Navigator navigator) => apply(navigator, sections);
      });

  @override
  String get hints => '↑↓ PgUp PgDn scroll · r check again · Esc back';

  @override
  List<String> get lines => [
    for (final section in sections) ...[
      Look.bold('${_mark(section.level)} ${section.title}'),
      for (final finding in section.findings) '  ${_mark(finding.level)} ${finding.subject}  ${finding.detail}',
      '',
    ],
  ];

  static String _mark(DoctorLevel level) => switch (level) {
    DoctorLevel.ok => Look.green('✓'),
    DoctorLevel.info => Look.dim('·'),
    DoctorLevel.warning => Look.yellow('!'),
    DoctorLevel.error => Look.red('✗'),
  };

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    if (msg is KeyMsg && msg.key == 'r') {
      navigator.say('Checking…');
      return run(locations, (navigator, sections) {
        this.sections = sections;
        navigator.say('Checked again.');
      });
    }
    return super.update(msg, navigator);
  }
}
