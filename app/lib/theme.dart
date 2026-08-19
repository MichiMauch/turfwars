import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Die eine Stelle, an der Farben festgelegt werden.
///
/// Vorher wählte jedes Widget seine Farbe selbst — 134 Literale im
/// Bildschirmcode und kein einziger Zugriff auf das Theme. Ein neu
/// geschriebener Knopf wurde dadurch zwangsläufig irgendwie bunt, weil es
/// nichts gab, von dem er hätte erben können.
///
/// Ausnahme, bewusst und einzig: die Spielerfarben in
/// `utils/player_colors.dart`. Die sind Daten — sie gehören dem Spieler und
/// nicht dem Erscheinungsbild. Ohne diese Grenze landet man beim nächsten
/// Sonderfall wieder bei Literalen.
///
/// Durchgesetzt wird die Regel von `test/no_hardcoded_colors_test.dart`.
class AppTheme {
  /// Das Dunkelgrün, aus dem das ganze Farbschema abgeleitet wird.
  static const Color seed = Color(0xFF1B5E20);

  static ColorScheme get _colors => ColorScheme.fromSeed(
        seedColor: seed,
        primary: seed,
      );

  /// Für die Statusleiste über dem grünen Kopfbereich: helle Symbole, sonst
  /// stünde die schwarze Uhrzeit auf Dunkelgrün.
  static const SystemUiOverlayStyle statusBarOnPrimary = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  );

  static ThemeData build() {
    final colors = _colors;

    return ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      scaffoldBackgroundColor: colors.surface,

      appBarTheme: AppBarTheme(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        systemOverlayStyle: statusBarOnPrimary,
      ),

      // Ohne diese drei erbt ein neu geschriebener Knopf nichts und bekommt
      // die Vorgabefarben von Material — genau so wurde der Standortknopf blau.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: colors.onPrimary),
      ),

      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(backgroundColor: colors.surface),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
      ),
    );
  }
}

/// Farben, die das ColorScheme nicht hergibt, aber die App braucht.
///
/// Material 3 kennt kein „Erfolg" und kein „Warnung" — es gibt nur primary,
/// secondary, tertiary und error. Statt an der Verwendungsstelle zu Literalen
/// zu greifen, stehen die Fälle hier, benannt nach ihrer Bedeutung.
extension AppColors on ColorScheme {
  /// Flächen, die über der Karte liegen und Text tragen müssen.
  Color get overlay => surface;
  Color get onOverlay => onSurface;

  /// Text zweiter Ordnung auf einer Überlagerung.
  Color get onOverlayMuted => onSurfaceVariant;

  /// Etwas ist gelungen — ein Gebiet erobert.
  Color get success => primary;
  Color get onSuccess => onPrimary;

  /// Ein Hinweis, der Aufmerksamkeit will, aber kein Fehler ist — eine offene
  /// Runde zum Beispiel.
  Color get notice => tertiary;
  Color get onNotice => onTertiary;
  Color get noticeContainer => tertiaryContainer;
  Color get onNoticeContainer => onTertiaryContainer;

  /// Werkzeuge zum Entwickeln. Bewusst abgesetzt, damit auf einen Blick klar
  /// ist, was nicht zum Spiel gehört.
  Color get devTool => secondary;
  Color get onDevTool => onSecondary;
}
