import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/setu_config.dart';
import 'screens/transaction_feed_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Log configuration state (informs developer whether secrets.json is loaded)
  SetuConfig.logStatus();

  // Set dark system navigation bar & status bar overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0F1015),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: SetthiApp()));
}

class SetthiApp extends StatelessWidget {
  const SetthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Setthi - Gen Z Finance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1015),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FFA3), // Neon Mint
          secondary: Color(0xFF8B5CF6), // Electric Purple
          surface: Color(0xFF171922),
          error: Color(0xFFFF5C5C),
          onPrimary: Colors.black,
          onSecondary: Colors.white,
          onSurface: Colors.white,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F1015),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const TransactionFeedScreen(),
    );
  }
}
