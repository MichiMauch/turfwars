import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hält die Regel aufrecht, dass Farben aus dem Theme kommen.
///
/// Vorher standen 134 Farbliterale in den Bildschirmen und kein einziger
/// Zugriff auf `Theme.of(context)`. Das ColorScheme in `main.dart` war
/// Dekoration — und jede neu geschriebene Zeile griff wieder daneben, weil es
/// nichts gab, von dem sie hätte erben können.
///
/// Einmal aufräumen hätte nichts geändert. Dieser Test ist der Teil, der
/// verhindert, dass es zurückkommt: Dart kennt dafür keine Lint-Regel, aber
/// ein Test läuft bei jedem `flutter test`.
///
/// Erlaubt bleibt `Colors.transparent` — das ist keine Farbe, sondern deren
/// Abwesenheit, und hat im Theme nichts zu suchen.
///
/// Farben, die **Daten** sind, gehören nach `lib/utils/`: die Spielerfarben in
/// `player_colors.dart` und Gold/Silber/Bronze in `rank_colors.dart`. Sie
/// gehören dem Spielstand, nicht dem Erscheinungsbild, und wandern deshalb
/// nicht mit, wenn die App eines Tages anders aussieht. Dieser Test prüft
/// `lib/screens/` — dort ist die Grenze.
void main() {
  final colorLiteral = RegExp(
    r'Colors\.(?!transparent\b)[a-zA-Z]+|Color\(0x[0-9A-Fa-f]{8}\)',
  );

  test('kein Farbliteral in lib/screens', () {
    final screens = Directory('lib/screens')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    expect(screens, isNotEmpty, reason: 'lib/screens nicht gefunden');

    final offences = <String>[];

    for (final file in screens) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Kommentare zählen nicht — dort steht oft, warum eine Farbe so ist.
        if (line.trimLeft().startsWith('//')) continue;

        for (final match in colorLiteral.allMatches(line)) {
          offences.add('${file.path}:${i + 1}  ${match.group(0)}');
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'Farben gehören ins Theme (lib/theme.dart), nicht in die '
          'Bildschirme. Nimm Theme.of(context).colorScheme.* — für Fälle, die '
          'das ColorScheme nicht kennt, gibt es die AppColors-Erweiterung in '
          'theme.dart. Ist die Farbe stattdessen Teil des Spielstands, gehört '
          'sie nach lib/utils/.\n  ${offences.join('\n  ')}',
    );
  });
}
