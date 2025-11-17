import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/storage_service.dart';
import '../services/signaling_service.dart';
import '../services/api.dart';
import '../services/call_service.dart';
import 'call_page.dart';

class HomePage extends StatefulWidget {
  final String userId;
  HomePage({required this.userId});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? username;
  final _idController = TextEditingController();
  bool _calling = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _inActiveCall = false; // Nueva variable para controlar llamadas activas
  
  // Buffer para señales WebRTC pendientes
  List<Map<String, dynamic>> _pendingWebRTCSignals = [];
  String? _currentCallerId;  // Función para obtener el nombre de usuario
  Future<String> fetchUsername(String userId) async {
    try {
      // Probar diferentes endpoints
      final endpoints = [
        '$baseUrl/api/users/$userId',
        '$baseUrl/api/user/$userId',
        '$baseUrl/api/profile/$userId',
        '$baseUrl/users/$userId',
      ];

      // Obtener token para autenticación
      final token = await StorageService.getToken();
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

      for (final url in endpoints) {
        try {
          print('fetchUsername: intentando endpoint $url');

          final response = await http.get(Uri.parse(url), headers: headers);

          print(
            'fetchUsername: status=${response.statusCode}, body=${response.body}',
          );

          if (response.statusCode == 200) {
            final dynamic data = json.decode(response.body);
            print('fetchUsername: datos recibidos: $data');

            String name = 'Usuario';
            if (data is Map<String, dynamic>) {
              // Buscar en diferentes campos posibles
              name =
                  data['username'] ??
                  data['name'] ??
                  data['displayName'] ??
                  data['user']?['username'] ??
                  data['user']?['name'] ??
                  data['user']?['displayName'] ??
                  'Usuario';
            }

            print('fetchUsername: nombre final obtenido: $name');
            if (name != 'Usuario') {
              return name; // Solo retornar si encontramos un nombre real
            }
          }
        } catch (e) {
          print('fetchUsername: error con endpoint $url: $e');
          continue;
        }
      }

      print('fetchUsername: todos los endpoints fallaron');
      return 'Usuario';
    } catch (e) {
      print('fetchUsername: excepción general: $e');
      return 'Usuario';
    }
  }

  // Función para enmascarar ID de usuario con formato 999-999-999
  String maskUserId(String id) {
    // Remover cualquier caracter no numérico
    final numbersOnly = id.replaceAll(RegExp(r'[^0-9]'), '');
    
    if (numbersOnly.length <= 3) {
      return numbersOnly;
    } else if (numbersOnly.length <= 6) {
      return '${numbersOnly.substring(0, 3)}-${numbersOnly.substring(3)}';
    } else if (numbersOnly.length <= 9) {
      return '${numbersOnly.substring(0, 3)}-${numbersOnly.substring(3, 6)}-${numbersOnly.substring(6)}';
    } else {
      // Si es más largo, usar solo los primeros 9 dígitos
      return '${numbersOnly.substring(0, 3)}-${numbersOnly.substring(3, 6)}-${numbersOnly.substring(6, 9)}';
    }
  }

  // Función para obtener lista de usuarios
  Future<List<Map<String, dynamic>>> fetchUsers(String currentUserId) async {
    try {
      final url = '$baseUrl/api/users';
      print('fetchUsers: intentando obtener usuarios desde $url');

      // Obtener token para autenticación
      final token = await StorageService.getToken();
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

      final response = await http.get(Uri.parse(url), headers: headers);

      print('fetchUsers: status=${response.statusCode}, body=${response.body}');

      if (response.statusCode == 200) {
        final dynamic rawData = json.decode(response.body);
        print('fetchUsers: tipo de datos recibidos: ${rawData.runtimeType}');

        List<dynamic> users = [];

        // Manejar diferentes estructuras de respuesta
        if (rawData is Map<String, dynamic>) {
          if (rawData.containsKey('users')) {
            users = rawData['users'] as List<dynamic>;
          } else if (rawData.containsKey('data')) {
            users = rawData['data'] as List<dynamic>;
          } else {
            print('fetchUsers: estructura de respuesta no reconocida');
            return [];
          }
        } else if (rawData is List<dynamic>) {
          users = rawData;
        } else {
          print(
            'fetchUsers: tipo de respuesta no soportado: ${rawData.runtimeType}',
          );
          return [];
        }

        final filteredUsers = users
            .where((user) => user is Map<String, dynamic>)
            .cast<Map<String, dynamic>>()
            .where((user) => (user['userId']?.toString() ?? user['id']?.toString()) != currentUserId)
            .toList();

        print(
          'fetchUsers: ${filteredUsers.length} usuarios encontrados (excluyendo usuario actual)',
        );
        print(
          'fetchUsers: usuarios: ${filteredUsers.map((u) => u['username'] ?? u['name'] ?? u['userId'] ?? u['id']).toList()}',
        );
        return filteredUsers;
      }
      print('fetchUsers: error de status ${response.statusCode}');
      return [];
    } catch (e) {
      print('fetchUsers: excepción: $e');
      return [];
    }
  }

  @override
  void initState() {
    super.initState();

    print('HomePage: initState - estado inicial _isConnected: $_isConnected');
    print('HomePage: initState - SignalingService.isConnected: ${SignalingService.instance.isConnected}');

    // Conectar al WebSocket para recibir llamadas entrantes
    _connectToSignaling();

    // Intentar obtener el nombre del usuario
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    try {
      // Primero intentar obtener del token JWT si existe
      final token = await StorageService.getToken();
      if (token != null) {
        try {
          // Decodificar JWT para obtener información del usuario
          final parts = token.split('.');
          if (parts.length == 3) {
            final payload = parts[1];
            // Agregar padding si es necesario
            String normalizedPayload = payload;
            while (normalizedPayload.length % 4 != 0) {
              normalizedPayload += '=';
            }

            final decoded = utf8.decode(base64Decode(normalizedPayload));
            final data = json.decode(decoded) as Map<String, dynamic>;

            print('Token JWT decodificado: $data');

            final nameFromToken =
                data['username'] ?? data['name'] ?? data['displayName'];
            if (nameFromToken != null) {
              setState(() => username = nameFromToken);
              print('Nombre obtenido del token: $nameFromToken');
              return; // Ya tenemos el nombre, no necesitamos hacer petición HTTP
            }
          }
        } catch (e) {
          print('Error decodificando token JWT: $e');
        }
      }

      // Si no pudimos obtener del token, hacer petición HTTP
      final name = await fetchUsername(widget.userId);
      setState(() => username = name);
    } catch (e) {
      print('Error cargando username: $e');
      setState(() => username = 'Usuario');
    }
  }

  Future<void> _connectToSignaling() async {
    try {
      // Obtener token para autenticación
      final token = await StorageService.getToken();

      // Convertir HTTP URL a WebSocket URL
      String wsUrl = baseUrl;
      if (wsUrl.startsWith('http://')) {
        wsUrl = wsUrl.replaceFirst('http://', 'ws://');
      } else if (wsUrl.startsWith('https://')) {
        wsUrl = wsUrl.replaceFirst('https://', 'wss://');
      }

      print('_connectToSignaling: conectando a $wsUrl');

      // Agregar token como query parameter si existe
      if (token != null) {
        final uri = Uri.parse(wsUrl);
        final params = Map<String, String>.from(uri.queryParameters);
        params['token'] = token;
        wsUrl = uri.replace(queryParameters: params).toString();
        print('_connectToSignaling: URL con token: $wsUrl');
      }

      await SignalingService.instance.connect(wsUrl, widget.userId);

      // Configurar callback para llamadas entrantes
      print('HomePage: Configurando callback onSignal');
      SignalingService.instance.onSignal = (signal) {
        print('HomePage: Callback onSignal ejecutado con señal: $signal');
        _handleIncomingSignal(signal);
      };

      SignalingService.instance.onConnected = () {
        print('HomePage: WebSocket conectado');
        _reconnectAttempts = 0;
        if (mounted) {
          setState(() {
            _isConnected = true;
          });
        }
      };

      SignalingService.instance.onDisconnected = () {
        print('HomePage: WebSocket desconectado');
        if (mounted) {
          setState(() {
            _isConnected = false;
          });
        }

        // Auto-reconectar con backoff
        if (_reconnectAttempts < 5) {
          _reconnectAttempts++;
          final delay = Duration(seconds: _reconnectAttempts * 2);
          _reconnectTimer?.cancel();
          _reconnectTimer = Timer(delay, () {
            if (mounted) _connectToSignaling();
          });
        }
      };

      SignalingService.instance.onError = (error) {
        print('HomePage: WebSocket error: $error');
      };

      // Verificar estado actual de conexión después de configurar callbacks
      if (mounted && SignalingService.instance.isConnected) {
        print('HomePage: SignalingService ya está conectado, actualizando estado UI');
        setState(() {
          _isConnected = true;
        });
      }
    } catch (e) {
      print('HomePage: failed to connect to WebSocket: $e');
    }
  }

  void _handleIncomingSignal(Map<String, dynamic> signal) {
    print('HomePage: Señal recibida: $signal');
    
    final type =
        signal['type'] ?? signal['Type'] ?? signal['event'] ?? signal['action'];
    
    print('HomePage: Tipo de señal detectado: $type');

    // Si estamos en una llamada activa, NO interceptar señales WebRTC
    // Dejar que el CallPage las maneje directamente
    if (_inActiveCall && (type == 'offer' || type == 'ice' || type == 'answer')) {
      print('HomePage: En llamada activa - NO interceptando señal WebRTC: $type');
      return;
    }

    // Señales de prueba (ping)
    if (type == 'ping') {
      print('HomePage: 🏓 PING recibido de: ${signal['from'] ?? 'unknown'}');
      print('HomePage: 🏓 Mensaje: ${signal['payload']?['message'] ?? 'sin mensaje'}');
      
      // Mostrar snackbar temporal
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🏓 Test signal recibido de ${signal['from'] ?? 'unknown'}'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Señales WebRTC se almacenan para procesarlas cuando se acepte la llamada
    if (type == 'offer' || type == 'ice' || type == 'answer') {
      final from = signal['from']?.toString();
      print('HomePage: Señal WebRTC de: $from, tipo: $type');

      // Agregar a buffer de señales WebRTC
      if (from != null) {
        _pendingWebRTCSignals.add(signal);

        // Si es una oferta, mostrar notificación de llamada entrante
        if (type == 'offer') {
          _currentCallerId = from;
          print('HomePage: Mostrando diálogo de llamada entrante para offer de: $from');
          _showIncomingCallDialog(from, signal['callId']?.toString());
        }
      }
      return;
    }

    // Señales de llamada entrante (basado en el servidor)
    if (type == 'incoming_call' || type == 'call' || type == 'CallRequest' || type == 'call_request' || type == 'call_notification') {
      final callerId = signal['from'] ?? signal['callerId'] ?? signal['caller'];
      final callId = signal['callId'] ?? signal['call_id'];
      print('HomePage: Llamada entrante de: $callerId, callId: $callId');

      if (callerId != null && callerId.toString() != widget.userId) {
        print('HomePage: Mostrando diálogo de llamada entrante para: $callerId');
        _showIncomingCallDialog(callerId.toString(), callId?.toString());
        _currentCallerId = callerId.toString();
      } else {
        print('HomePage: Llamada ignorada - callerId es null o es el mismo usuario');
      }
    } else {
      print('HomePage: Tipo de señal no reconocido para llamadas: $type');
    }
  }

  void _showIncomingCallDialog(String callerId, String? callId) {
    print('HomePage: _showIncomingCallDialog llamado para callerId: $callerId, callId: $callId');
    
    if (!mounted) {
      print('HomePage: Widget no está mounted, no se puede mostrar diálogo');
      return;
    }

    print('HomePage: Mostrando diálogo de llamada entrante');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Llamada entrante'),
        content: Text('Llamada de usuario: $callerId'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Limpiar buffer al rechazar
              _pendingWebRTCSignals.clear();
              _currentCallerId = null;
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.call_end, color: Colors.white),
                SizedBox(width: 5),
                Text('Rechazar', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _acceptCall(callerId, callId);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.call, color: Colors.white),
                SizedBox(width: 5),
                Text('Aceptar', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _acceptCall(String callerId, String? callId) {
    // Marcar que estamos en una llamada activa
    _inActiveCall = true;
    print('HomePage: Marcando llamada como activa - _inActiveCall = true');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallPage(
          myUserId: widget.userId,
          otherUserId: callerId,
          callId: callId,
          isCaller: false, // Es el receptor
          pendingSignals: List.from(
            _pendingWebRTCSignals,
          ), // Pasar copia de las señales
        ),
      ),
    ).then((_) {
      // Cuando regresa del CallPage, marcar como no activa
      _inActiveCall = false;
      print('HomePage: Llamada terminada - _inActiveCall = false');
    });

    // Limpiar buffer después de pasar al CallPage
    _pendingWebRTCSignals.clear();
    _currentCallerId = null;
  }

  @override
  void dispose() {
    // SOLO limpiar callbacks si NO hay una llamada activa
    // Permitir que CallPage use la conexión WebSocket existente

    _reconnectTimer?.cancel();
    super.dispose();
  }

  Future<void> startCall(String otherUserId) async {
    if (_calling || otherUserId.isEmpty) {
      print('startCall: Llamada cancelada - _calling=$_calling, otherUserId=$otherUserId');
      return;
    }
    
    setState(() => _calling = true);

    print('startCall: Iniciando llamada de ${widget.userId} a $otherUserId');

    try {
      // Usar el endpoint HTTP correcto del servidor
      final response = await startCallRequest(
        callerId: widget.userId,
        calleeId: otherUserId,
      );

      print('startCall: Respuesta del servidor: $response');

      if (response != null) {
      // Marcar que estamos en una llamada activa
      _inActiveCall = true;
      print('startCall: Marcando llamada como activa - _inActiveCall = true');

      // Navegar a CallPage con el callId del servidor
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallPage(
            myUserId: widget.userId,
            otherUserId: otherUserId,
            callId: response['callId'],
            isCaller: true,
          ),
        ),
      ).then((_) {
        // Cuando regresa del CallPage, marcar como no activa
        _inActiveCall = false;
        print('startCall: Llamada terminada - _inActiveCall = false');
      });        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Llamada iniciada con ID: ${response['callId']}'))
          );
        }
      } else {
        print('startCall: El servidor no devolvió respuesta válida');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: No se pudo iniciar la llamada'))
          );
        }
      }
      
    } catch (e) {
      print('startCall: Error iniciando llamada: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'))
        );
      }
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  Future<void> _callUser() async {
    final inputId = _idController.text.trim();
    if (inputId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Confirmar llamada'),
        content: Text('¿Llamar al usuario $inputId?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Llamar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Marcar que estamos en una llamada activa
      _inActiveCall = true;
      print('_callUser: Marcando llamada como activa - _inActiveCall = true');
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallPage(
            myUserId: widget.userId,
            otherUserId: inputId,
            callId: null,
            isCaller: true,
          ),
        ),
      ).then((_) {
        // Cuando regresa del CallPage, marcar como no activa
        _inActiveCall = false;
        print('_callUser: Llamada terminada - _inActiveCall = false');
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Iniciando llamada a $inputId')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Bienvenido'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Usuario: ${username ?? 'Cargando...'}'),
                        SizedBox(width: 10),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _isConnected ? Colors.green : Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text('ID: ${maskUserId(widget.userId)}'),
                  ],
                ),
              ),
            ),
            SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hacer una llamada',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10),
                    TextField(
                      controller: _idController,
                      decoration: InputDecoration(
                        labelText: 'ID del usuario a llamar',
                        border: OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(Icons.call),
                          onPressed: _calling ? null : _callUser,
                        ),
                      ),
                      onSubmitted: (_) => _callUser(),
                    ),
                    if (_calling)
                      Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Iniciando llamada...'),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 20),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Usuarios disponibles',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 10),
                      Expanded(
                        child: FutureBuilder<List<Map<String, dynamic>>>(
                          future: fetchUsers(widget.userId),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return Center(child: CircularProgressIndicator());
                            }
                            if (snapshot.hasError) {
                              return Center(
                                child: Text('Error: ${snapshot.error}'),
                              );
                            }
                            final users = snapshot.data ?? [];
                            if (users.isEmpty) {
                              return Center(
                                child: Text('No hay usuarios disponibles'),
                              );
                            }
                            return ListView.builder(
                              itemCount: users.length,
                              itemBuilder: (context, index) {
                                final user = users[index];
                                final userName =
                                    user['username'] ??
                                    user['name'] ??
                                    user['displayName'] ??
                                    'Usuario ${user['userId'] ?? user['id']}';
                                final userId = user['userId']?.toString() ?? user['id']?.toString() ?? '';
                                print('HomePage: Usuario en lista - nombre: $userName, userId: $userId');
                                return ListTile(
                                  leading: CircleAvatar(
                                    child: Icon(Icons.person),
                                  ),
                                  title: Text(userName),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(
                                          Icons.send,
                                          color: Colors.blue,
                                          size: 20,
                                        ),
                                        onPressed: () {
                                          print('HomePage: 🧪 Enviando test signal a userId: $userId');
                                          SignalingService.instance.sendSignal(userId, 'ping', {
                                            'message': 'test from ${widget.userId}',
                                            'timestamp': DateTime.now().millisecondsSinceEpoch,
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          Icons.video_call,
                                          color: Colors.green,
                                        ),
                                        onPressed: () {
                                          print('HomePage: Iniciando llamada a userId: $userId');
                                          startCall(userId);
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
