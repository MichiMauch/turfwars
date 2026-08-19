import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/game_provider.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TurfWarsApp());
}

class TurfWarsApp extends StatelessWidget {
  const TurfWarsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => GameProvider(),
      child: MaterialApp(
        title: 'Turf Wars',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        home: const LoginScreen(),
      ),
    );
  }
}
