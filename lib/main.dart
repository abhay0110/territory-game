import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/theme/game_ui_tokens.dart';
import 'src/presentation/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://poscpubexjiwjljqrtgy.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBvc2NwdWJleGppd2psanFydGd5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI2NTk0NzcsImV4cCI6MjA4ODIzNTQ3N30.nTY3mZehHV2-gSv1huK1LyM1fi1FGC9PnHkoneOoTPg',
  );

  runApp(const TerritoryGameApp());
}

class TerritoryGameApp extends StatelessWidget {
  const TerritoryGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Territory Game',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: GameUiTokens.bg0,
        colorScheme: ColorScheme.fromSeed(
          seedColor: GameUiTokens.accentPrimary,
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.rajdhaniTextTheme(ThemeData.dark().textTheme)
            .apply(
              bodyColor: GameUiTokens.textHi,
              displayColor: GameUiTokens.textHi,
            ),
      ),
      home: const HomeScreen(),
    );
  }
}
