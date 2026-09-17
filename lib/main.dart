import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/setu_config.dart';
import 'config/supabase_config.dart';
import 'providers/auth_providers.dart';
import 'screens/auth_screen.dart';
import 'screens/transaction_feed_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Log configuration state (informs developer whether secrets.json is loaded)
  SetuConfig.logStatus();

  // Initialize Supabase if configured in secrets.json
  if (SupabaseConfig.isConfigured) {
    await SupabaseConfig.initialize();
  }
  SupabaseConfig.logStatus();

  // Set dark system navigation bar & status bar overlay style (pure OLED black)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF000000),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: SetthiApp()));
}

class SetthiApp extends ConsumerWidget {
  const SetthiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);

    return MaterialApp(
      title: 'Setthi - Gen Z Finance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF34D399), // DPC Accent Positive
          secondary: Color(0xFF38BDF8), // DPC Accent Primary / Currency
          surface: Color(0xFF0D0D11), // DPC Surface Dark
          error: Color(0xFFF43F5E), // DPC Accent Negative
          onPrimary: Color(0xFF121214),
          onSecondary: Colors.white,
          onSurface: Colors.white,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: isAuthenticated
          ? const TransactionFeedScreen()
          : const AuthScreen(),
    );
  }
}
