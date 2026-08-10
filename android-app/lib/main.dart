import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/websocket_service.dart';
import 'services/box_provisioning.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ContinuumApp());
}

// Ultra dark theme colors, see ARCHITECTURE.md.
class AppColors {
  static const background = Color(0xFF0A0A0A);
  static const card = Color(0xFF141414);
  static const divider = Color(0xFF2A2A2A);
  static const accent = Color(0xFF64FFDA);
  static const textPrimary = Color(0xFFE0E0E0);
  static const textSecondary = Color(0xFF888888);
  static const statusGreen = Color(0xFF4CAF50);
  static const statusRed = Color(0xFFFF5252);
  static const statusOrange = Color(0xFFFFAB40);
  static const statusBlue = Color(0xFF448AFF);
}

class ContinuumApp extends StatelessWidget {
  const ContinuumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WebSocketService()),
        ChangeNotifierProvider(create: (_) => BoxProvisioningService()),
      ],
      child: MaterialApp(
        title: 'continium',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: AppColors.background,
          cardColor: AppColors.card,
          dividerColor: AppColors.divider,
          colorScheme: ColorScheme.dark(
            primary: AppColors.accent,
            secondary: AppColors.accent,
            surface: AppColors.card,
          ),
          textTheme: const TextTheme(
            bodyLarge: TextStyle(color: AppColors.textPrimary),
            bodyMedium: TextStyle(color: AppColors.textPrimary),
            bodySmall: TextStyle(color: AppColors.textSecondary),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.background,
            foregroundColor: AppColors.textPrimary,
            elevation: 0,
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
