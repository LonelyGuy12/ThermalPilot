import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait for consistent chart layout
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D1117),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const ThermalPilotApp());
}

class ThermalPilotApp extends StatelessWidget {
  const ThermalPilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ThermalPilot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: const Color(0xFF00E5A0),
          surface: const Color(0xFF161B27),
          error: Colors.redAccent,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D1117),
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70),
          bodySmall: TextStyle(color: Colors.white54),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
