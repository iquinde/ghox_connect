import 'package:flutter/material.dart';
import 'pages/startup_page.dart';
import 'pages/home_page.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print('.env not found, continuing with defaults: $e');
  }

  // Leer userId antes de arrancar la app para evitar condiciones de carrera
  String? initialUserId;
  try {
    initialUserId = await StorageService.getUserId();
    print('main: initialUserId=$initialUserId');
  } catch (e) {
    print('main: error reading userId: $e');
  }

  runApp(GhoxApp(initialUserId: initialUserId));
}

class GhoxApp extends StatelessWidget {
  final String? initialUserId;
  GhoxApp({this.initialUserId, Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ghox Connect',
      debugShowCheckedModeBanner: false,
      home: initialUserId != null && initialUserId!.isNotEmpty
          ? HomePage(userId: initialUserId!)
          : StartupPage(),
    );
  }
}
