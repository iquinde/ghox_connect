import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/storage_service.dart';
import '../services/signaling_service.dart';
import '../services/api.dart';
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
  String? _currentCallerId;
  String? _currentCallId; // Para rastrear callId actual

  // Función para obtener el nombre de usuario
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
          final response = await http.get(Uri.parse(url), headers: headers);

          if (response.statusCode == 200) {
            final dynamic data = json.decode(response.body);

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

      if (response.statusCode == 200) {
        final dynamic rawData = json.decode(response.body);

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
            .where(
              (user) =>
                  (user['userId']?.toString() ?? user['id']?.toString()) !=
                  currentUserId,
            )
            .toList();

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
    print(
      'HomePage: initState - SignalingService.isConnected: ${SignalingService.instance.isConnected}',
    );

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
      print('🔗 [HomePage] *** INICIANDO CONEXIÓN WEBSOCKET ***');
      print('🔗 [HomePage] *** BASE URL ORIGINAL *** $baseUrl');
      print('🔗 [HomePage] *** USER ID *** ${widget.userId}');

      // Obtener token para autenticación
      final token = await StorageService.getToken();
      print(
        '🔑 [HomePage] *** TOKEN *** ${token != null ? '${token.substring(0, 30)}...' : 'null'}',
      );

      // Convertir HTTP URL a WebSocket URL
      String wsUrl = baseUrl;
      if (wsUrl.startsWith('http://')) {
        wsUrl = wsUrl.replaceFirst('http://', 'ws://');
      } else if (wsUrl.startsWith('https://')) {
        wsUrl = wsUrl.replaceFirst('https://', 'wss://');
      }

      print('🔗 [HomePage] *** WS URL CONVERTIDO *** $wsUrl');

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
        print(
          'HomePage: SignalingService ya está conectado, actualizando estado UI',
        );
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
    if (_inActiveCall &&
        (type == 'offer' || type == 'ice' || type == 'answer')) {
      print(
        'HomePage: En llamada activa - NO interceptando señal WebRTC: $type',
      );
      return;
    }

    // Manejo de llamadas entrantes (protocolo correcto)
    if (type == 'incoming-call') {
      final callerId = signal['from']?.toString();
      final callId = signal['callId']?.toString();
      final meta = signal['meta'] ?? {};

      print('HomePage: 📞 Llamada entrante de: $callerId, callId: $callId');
      print('HomePage: 📋 Meta: $meta');

      if (callerId != null && callerId != widget.userId) {
        _currentCallerId = callerId;
        _currentCallId = callId;
        print('HomePage: Mostrando diálogo de llamada entrante');
        _showIncomingCallDialog(callerId, callId);
      }
      return;
    }

    // Respuestas de llamada
    if (type == 'call-accepted') {
      print('HomePage: ✅ Llamada aceptada por el receptor');
      return;
    }

    if (type == 'call-rejected') {
      print('HomePage: ❌ Llamada rechazada por el receptor');
      return;
    }

    // Señales WebRTC se almacenan para procesarlas cuando se acepte la llamada
    if (type == 'offer' || type == 'ice' || type == 'answer') {
      final from = signal['from']?.toString();
      print('HomePage: Señal WebRTC de: $from, tipo: $type');

      // Agregar a buffer de señales WebRTC
      if (from != null) {
        _pendingWebRTCSignals.add(signal);

        // Si es una oferta Y no estamos en llamada, mostrar notificación
        if (type == 'offer' && !_inActiveCall) {
          _currentCallerId = from;
          print(
            'HomePage: Mostrando diálogo de llamada entrante para offer de: $from',
          );
          _showIncomingCallDialog(from, signal['callId']?.toString());
        }
      }
      return;
    }

    // Señales de llamada entrante (basado en el servidor)
    if (type == 'incoming_call' ||
        type == 'call' ||
        type == 'CallRequest' ||
        type == 'call_request' ||
        type == 'call_notification') {
      final callerId = signal['from'] ?? signal['callerId'] ?? signal['caller'];
      final callId = signal['callId'] ?? signal['call_id'];
      print('HomePage: Llamada entrante de: $callerId, callId: $callId');

      if (callerId != null && callerId.toString() != widget.userId) {
        print(
          'HomePage: Mostrando diálogo de llamada entrante para: $callerId',
        );
        _showIncomingCallDialog(callerId.toString(), callId?.toString());
        _currentCallerId = callerId.toString();
      } else {
        print(
          'HomePage: Llamada ignorada - callerId es null o es el mismo usuario',
        );
      }
    } else {
      print('HomePage: Tipo de señal no reconocido para llamadas: $type');
    }
  }

  void _showIncomingCallDialog(String callerId, String? callId) {
    print(
      'HomePage: _showIncomingCallDialog llamado para callerId: $callerId, callId: $callId',
    );

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
    print(
      '✅ [HomePage] *** ACEPTANDO LLAMADA *** de $callerId con callId: $callId',
    );
    print('✅ [HomePage] *** CALL ACCEPT *** mi userId: ${widget.userId}');
    print(
      '✅ [HomePage] *** PENDING SIGNALS *** ${_pendingWebRTCSignals.length} señales pendientes',
    );

    try {
      // Marcar que estamos en una llamada activa
      _inActiveCall = true;
      print('✅ [HomePage] *** CALL STATE *** _inActiveCall = true');

      print('✅ [HomePage] *** NAVEGANDO A CALL PAGE *** como receptor');

      if (!mounted) {
        print(
          '❌ [HomePage] *** ERROR *** Widget no montado, cancelando navegación',
        );
        return;
      }

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
          )
          .then((_) {
            // Cuando regresa del CallPage, marcar como no activa
            if (mounted) {
              _inActiveCall = false;
              print(
                '✅ [HomePage] *** LLAMADA ACEPTADA TERMINADA *** _inActiveCall = false',
              );
            }
          })
          .catchError((error) {
            print('❌ [HomePage] *** ERROR EN NAVEGACIÓN *** $error');
            if (mounted) {
              _inActiveCall = false;
            }
          });

      // Limpiar buffer después de pasar al CallPage
      _pendingWebRTCSignals.clear();
      _currentCallerId = null;
      print(
        '✅ [HomePage] *** BUFFER LIMPIADO *** pendingSignals y currentCallerId reset',
      );
    } catch (e, stackTrace) {
      print('❌ [HomePage] *** CRASH EN _acceptCall *** $e');
      print('❌ [HomePage] *** STACK TRACE *** $stackTrace');
      if (mounted) {
        _inActiveCall = false;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al aceptar llamada: $e')));
      }
    }
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
      print(
        '⚠️ [HomePage] *** CALL CANCELADO *** _calling=$_calling, otherUserId=$otherUserId',
      );
      return;
    }

    setState(() => _calling = true);

    print(
      '📞 [HomePage] *** INICIANDO LLAMADA *** de ${widget.userId} a $otherUserId',
    );
    print('📞 [HomePage] *** INICIANDO LLAMADA *** username: $username');

    try {
      // Protocolo correcto: enviar call-init via WebSocket (como HTML)
      final metadata = {
        'displayName': username ?? 'Usuario',
        'from': widget.userId,
      };

      print('📞 [HomePage] *** CALL-INIT *** enviando con metadata: $metadata');

      SignalingService.instance.sendCallInit(otherUserId, metadata);

      print('✅ [HomePage] *** CALL-INIT *** enviado via WebSocket');

      // Marcar que estamos en una llamada activa
      _inActiveCall = true;
      print('📞 [HomePage] *** CALL STATE *** _inActiveCall = true');

      // Navegar a CallPage
      print('📞 [HomePage] *** NAVEGANDO *** a CallPage');
      print(
        '📞 [HomePage] *** CALL PARAMS *** myUserId: ${widget.userId}, otherUserId: $otherUserId',
      );

      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallPage(
            myUserId: widget.userId,
            otherUserId: otherUserId,
            callId: null, // No hay callId aún
            isCaller: true,
          ),
        ),
      );

      // Cuando regresa del CallPage, marcar como no activa
      _inActiveCall = false;
      print('📞 [HomePage] *** CALL TERMINADA *** _inActiveCall = false');
      print('📞 [HomePage] *** CALL RESULT *** $result');
    } catch (e) {
      print('❌ [HomePage] *** ERROR INICIANDO LLAMADA *** $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error iniciando llamada: $e')));
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
                                final userId =
                                    user['userId']?.toString() ??
                                    user['id']?.toString() ??
                                    '';
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
                                          Icons.video_call,
                                          color: Colors.green,
                                        ),
                                        onPressed: () {
                                          print(
                                            'HomePage: Iniciando llamada a userId: $userId',
                                          );
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
