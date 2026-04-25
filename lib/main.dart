import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/theme/game_ui_tokens.dart';
import 'src/presentation/screens/home_screen.dart';
import 'src/services/notification_service.dart';

Future<void> main() async {
  // Tracks whether Firebase initialized successfully — gates all Crashlytics calls.
  var firebaseReady = false;

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Supabase init — must complete before app starts using it.
    try {
      await Supabase.initialize(
        url: 'https://poscpubexjiwjljqrtgy.supabase.co',
        anonKey:
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBvc2NwdWJleGppd2psanFydGd5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI2NTk0NzcsImV4cCI6MjA4ODIzNTQ3N30.nTY3mZehHV2-gSv1huK1LyM1fi1FGC9PnHkoneOoTPg',
      );
    } catch (e) {
      debugPrint('Supabase init failed: $e');
    }

    // Firebase init — only wire Crashlytics if it actually succeeded.
    try {
      await Firebase.initializeApp();
      firebaseReady = true;
    } catch (e) {
      debugPrint('Firebase init failed: $e');
    }

    if (firebaseReady) {
      try {
        FlutterError.onError =
            FirebaseCrashlytics.instance.recordFlutterFatalError;
        await FirebaseCrashlytics.instance
            .setCrashlyticsCollectionEnabled(true);
      } catch (e) {
        debugPrint('Crashlytics wiring failed: $e');
      }
    }

    // Edge-to-edge: transparent status & nav bars with light (white) icons.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    runApp(const ProviderScope(child: TerritoryGameApp()));

    // Defer notification init until after first frame — must never block startup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Fire-and-forget. NotificationService.initialize() already swallows errors.
      unawaited(NotificationService().initialize());
    });
  }, (error, stack) {
    if (firebaseReady) {
      try {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } catch (_) {
        // Swallow — never let error reporting itself crash startup.
      }
    } else {
      debugPrint('Uncaught zone error (Firebase not ready): $error\n$stack');
    }
  });
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
