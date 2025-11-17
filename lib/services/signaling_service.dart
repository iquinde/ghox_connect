import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'storage_service.dart';

class SignalingService {
  SignalingService._internal();
  static final SignalingService instance = SignalingService._internal();

  // Callbacks
  void Function(Map<String, dynamic>)? onSignal;
  void Function(dynamic)? onError;
  void Function()? onConnected;
  void Function()? onDisconnected;

  WebSocketChannel? _channel;
  bool _connected = false;
  final List<String> _outQueue = [];
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  StreamSubscription? _subscription;
  String? _lastBaseUrl;
  String? _lastUserId;
  Timer? _heartbeatTimer;

  bool get isConnected => _connected;

  Future<void> connect(String baseUrl, String userId) async {
    await disconnect();
    
    _lastBaseUrl = baseUrl;
    _lastUserId = userId;

    try {
      // Obtener token JWT para autenticación WebSocket
      final token = await StorageService.getToken();
      final uri = await _buildWsUri(baseUrl, userId, token);
      print('SignalingService: Conectando a: $uri');
      
      _channel = WebSocketChannel.connect(uri);
      
      _subscription = _channel!.stream.listen(
        (data) {
          _onMessage(data);
        },
        onError: (e) {
          print('SignalingService: WebSocket error: $e');
          _handleError(e);
        },
        onDone: () {
          _onDone();
        },
      );
      
      _onOpen();
    } catch (e) {
      print('SignalingService: Failed to connect: $e');
      _handleError(e);
      _scheduleReconnect(baseUrl, userId);
    }
  }

  Future<Uri> _buildWsUri(String baseUrl, String userId, String? token) async {
    // If already ws/wss, use as-is and append params
    if (baseUrl.startsWith('ws://') || baseUrl.startsWith('wss://')) {
      final u = Uri.parse(baseUrl);
      final params = Map<String, String>.from(u.queryParameters);
      params['userId'] = userId;
      if (token != null) {
        params['token'] = token;
      }
      return u.replace(queryParameters: params);
    }
    
    // convert http(s) -> ws(s)
    final ws = baseUrl.startsWith('https://') ? baseUrl.replaceFirst('https://', 'wss://') : baseUrl.replaceFirst('http://', 'ws://');
    final uri = Uri.parse(ws);
    final params = Map<String, String>.from(uri.queryParameters);
    params['userId'] = userId;
    if (token != null) {
      params['token'] = token;
    }
    return uri.replace(queryParameters: params);
  }

  void _onOpen() {
    print('SignalingService: Conexión WebSocket establecida');
    _connected = true;
    _reconnectAttempts = 0;
    onConnected?.call();
    
    // flush queue
    for (final m in _outQueue) {
      _sendRaw(m);
    }
    _outQueue.clear();
    
    // Start heartbeat to keep connection alive
    _startHeartbeat();
    print('SignalingService: Heartbeat iniciado');
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      if (_connected) {
        try {
          sendSignal('server', 'ping', {});
        } catch (e) {
          print('SignalingService: Heartbeat failed: $e');
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _onMessage(dynamic data) {
    print('SignalingService: 📨 Mensaje recibido (tipo: ${data.runtimeType}): $data');
    try {
      final decoded = data is String ? json.decode(data) : data;
      print('SignalingService: 📨 Mensaje decodificado (tipo: ${decoded.runtimeType}): $decoded');
      
      if (decoded is Map) {
        final signal = Map<String, dynamic>.from(decoded);
        print('SignalingService: 📨 Procesando como Map: $signal');
        print('SignalingService: 📨 Ejecutando callback onSignal');
        onSignal?.call(signal);
      } else if (decoded is String) {
        final signal = {'msg': decoded};
        print('SignalingService: 📨 Procesando como String: $signal');
        onSignal?.call(signal);
      } else {
        final signal = {'data': decoded};
        print('SignalingService: 📨 Procesando como data: $signal');
        onSignal?.call(signal);
      }
    } catch (e) {
      print('SignalingService: ❌ Error decodificando mensaje: $e');
      // fallback: try to wrap raw
      final signal = {'raw': data};
      print('SignalingService: 📨 Procesando como raw: $signal');
      onSignal?.call(signal);
    }
  }

  void _onDone() {
    _connected = false;
    _stopHeartbeat();
    onDisconnected?.call();
    
    // Auto-reconnect if we have connection details
    if (_lastBaseUrl != null && _lastUserId != null) {
      _scheduleReconnect(_lastBaseUrl!, _lastUserId!);
    }
  }

  void _handleError(dynamic e) {
    onError?.call(e);
    _connected = false;
    _stopHeartbeat();
    
    // Auto-reconnect on error
    if (_lastBaseUrl != null && _lastUserId != null) {
      _scheduleReconnect(_lastBaseUrl!, _lastUserId!);
    }
  }

  void sendSignal(String to, String type, Map<String, dynamic>? payload) {
    // Agregar 'from' al mensaje para identificar el remitente
    final msgMap = {
      'to': to,
      'from': _lastUserId ?? 'unknown', 
      'type': type, 
      'payload': payload ?? {}
    };
    final msg = json.encode(msgMap);
    
    print('SignalingService: 📤 Enviando señal - from: $_lastUserId to: $to, type: $type');
    print('SignalingService: 📤 Payload size: ${payload?.toString().length ?? 0} chars');
    print('SignalingService: 📤 Connected: $_connected');
    print('SignalingService: 📤 Mensaje completo: $msg');
    
    if (_connected) {
      print('SignalingService: 📤 Enviando inmediatamente via WebSocket');
      _sendRaw(msg);
    } else {
      print('SignalingService: 📤 WebSocket desconectado, agregando a cola (${_outQueue.length + 1} mensajes)');
      _outQueue.add(msg);
    }
  }

  // Método específico para señales WebRTC (offer, answer, ice)
  void sendWebRTCSignal(String to, String type, Map<String, dynamic> payload) {
    // Para WebRTC, el servidor espera directamente los campos en el nivel raíz
    final msgMap = {
      'to': to,
      'type': type,
      ...payload, // Expandir payload directamente
    };
    final msg = json.encode(msgMap);
    
    print('SignalingService: 📤 Enviando WebRTC - to: $to, type: $type');
    print('SignalingService: 📤 Mensaje WebRTC: $msg');
    
    if (_connected) {
      _sendRaw(msg);
    } else {
      _outQueue.add(msg);
    }
  }

  void _sendRaw(String message) {
    try {
      if (_channel == null) {
        print('SignalingService: ❌ No se puede enviar, _channel es null');
        return;
      }
      
      print('SignalingService: 📡 Enviando mensaje via WebSocket: ${message.length} chars');
      _channel!.sink.add(message);
      print('SignalingService: ✅ Mensaje enviado exitosamente');
    } catch (e) {
      print('SignalingService: ❌ Error enviando mensaje: $e');
      _handleError(e);
    }
  }

  Future<void> disconnect() async {
    try {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _stopHeartbeat();
      
      await _subscription?.cancel();
      _subscription = null;
      
      if (_channel != null) {
        try {
          await _channel!.sink.close();
        } catch (_) {}
        _channel = null;
      }
    } catch (_) {}
    _connected = false;
  }

  void _scheduleReconnect(String baseUrl, String userId) {
    if (_reconnectAttempts > 10) {
      print('SignalingService: Max reconnect attempts reached');
      return;
    }
    _reconnectAttempts++;
    
    final delay = _reconnectAttempts <= 3 ? 2 : (_reconnectAttempts <= 6 ? 5 : 10);
    
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_connected) {
        connect(baseUrl, userId);
      }
    });
  }

  void dispose() {
    disconnect();
    _stopHeartbeat();
    onSignal = null;
    onError = null;
    onConnected = null;
    onDisconnected = null;
  }
}