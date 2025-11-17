import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/storage_service.dart';
import '../services/api.dart';
import 'home_page.dart';

class StartupPage extends StatefulWidget {
  const StartupPage({Key? key}) : super(key: key);

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  bool _loading = true;
  String? _userId;
  final _usernameCtrl = TextEditingController();
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Esperar a que StorageService devuelva userId (si existe)
    try {
      final stored = await StorageService.getUserId();
      if (stored != null && stored.isNotEmpty) {
        // si ya existe -> navegar directamente (replace)
        _navigateToHome(stored);
        return;
      }
    } catch (e) {
      print('StartupPage: error leyendo userId: $e');
    }

    // si no hay userId, mostrar formulario de registro
    if (mounted)
      setState(() {
        _loading = false;
      });
  }

  Future<void> _navigateToHome(String userId) async {
    // navegar reemplazando (evita volver a startup)
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomePage(userId: userId)),
    );
  }

  Future<Map<String, dynamic>?> _registerUser(String username) async {
    try {
      final uri = Uri.parse('$baseUrl/api/auth/register');
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'username': username}),
          )
          .timeout(const Duration(seconds: 10));
      print('registerUser status:${resp.statusCode} body:${resp.body}');
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return json.decode(resp.body) as Map<String, dynamic>;
      } else {
        print('registerUser failed: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      print('registerUser exception: $e');
    }
    return null;
  }

  Future<void> _onRegisterPressed() async {
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ingresa un nombre')));
      return;
    }
    setState(() => _registering = true);

    final res = await _registerUser(username);
    if (res != null) {
      // normalizar distintas respuestas: { user: { id: ... } } o { id: ..., username: ... }
      String? id;
      if (res['user'] is Map && res['user']['id'] != null)
        id = res['user']['id'].toString();
      id ??=
          res['id']?.toString() ??
          res['data']?['id']?.toString() ??
          res['user']?['_id']?.toString();

      if (id != null && id.isNotEmpty) {
        // guardar id localmente y navegar solo cuando termine
        await StorageService.saveUserId(id);
        print('StartupPage: saved userId $id');
        if (mounted) _navigateToHome(id);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Respuesta inválida del servidor')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error registrando usuario')),
      );
    }

    if (mounted) setState(() => _registering = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Iniciar')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'Regístrate para obtener tu ID',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre de usuario',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _registering ? null : _onRegisterPressed,
              child: _registering
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Registrar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }
}
