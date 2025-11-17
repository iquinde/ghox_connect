import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';

String get baseUrl {
  // Prioridad: variable de entorno -> plataforma específica
  final envUrl = dotenv.env['API_BASE_URL'];
  if (envUrl != null && envUrl.isNotEmpty) {
    return envUrl;
  }
  
  if (kIsWeb) {
    // Para web, usar localhost directo
    return 'http://localhost:8080';
  } else {
    // Para móvil (emulador Android usa 10.0.2.2, iOS usa localhost)
    return 'http://10.0.2.2:8080';
  }
}
