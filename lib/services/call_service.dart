import 'dart:convert';
import 'package:http/http.dart' as http;
import 'storage_service.dart';
import 'api.dart';

/// Intenta iniciar llamada probando varios endpoints posibles.
/// No lanza excepción si falla; retorna el JSON decodificado o null.
Future<Map<String, dynamic>?> startCallRequest({
  required String callerId,
  required String calleeId,
}) async {
  final endpoints = <String>[
    '/api/calls/start',
    '/api/calls',
    '/api/call',
    '/api/call/start',
    '/calls',
    '/call/start',
  ];

  final token = await StorageService.getToken();
  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  final body = json.encode({'from': callerId, 'to': calleeId});
  print(
    'startCallRequest: trying from=$callerId to=$calleeId baseUrl=$baseUrl',
  );

  for (final path in endpoints) {
    try {
      final uri = Uri.parse('$baseUrl$path');
      print('startCallRequest: POST $uri');
      final response = await http
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));
      print(
        'startCallRequest: status=${response.statusCode} body=${response.body}',
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        try {
          final decoded = json.decode(response.body);
          if (decoded is Map<String, dynamic>) return decoded;
          // si el backend devuelve lista o string, devolver raw
          return {'raw': decoded};
        } catch (e) {
          print(
            'startCallRequest: JSON decode error: $e -- returning raw body',
          );
          return {'raw': response.body};
        }
      } else {
        print(
          'startCallRequest: endpoint $path returned ${response.statusCode}',
        );
      }
    } catch (e) {
      print('startCallRequest: request to $path failed: $e');
    }
  }

  print('startCallRequest: all endpoints tried, none returned 200/201');
  return null;
}

/// Intenta terminar llamada probando varios endpoints posibles.
/// Retorna true si alguno responde OK/204.
Future<bool> endCallRequest(String callId) async {
  final token = await StorageService.getToken();
  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  final candidates = [
    '/api/calls/$callId/end',
    '/api/calls/$callId',
    '/api/call/$callId/end',
    '/api/call/$callId',
    '/calls/$callId/end',
    '/call/$callId',
  ];

  for (final path in candidates) {
    try {
      final uri = Uri.parse('$baseUrl$path');
      print('endCallRequest: POST $uri');
      final response = await http
          .post(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      print(
        'endCallRequest: status=${response.statusCode} body=${response.body}',
      );
      if (response.statusCode == 200 || response.statusCode == 204) return true;
    } catch (e) {
      print('endCallRequest: request to $path failed: $e');
    }
  }
  print('endCallRequest: all endpoints tried, none succeeded');
  return false;
}
