import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/call_service.dart';
import '../services/api.dart';

class CallPage extends StatefulWidget {
  final String myUserId;
  final String otherUserId;
  final String? callId;
  final bool isCaller;
  final List<Map<String, dynamic>>? pendingSignals;

  CallPage({
    required this.myUserId,
    required this.otherUserId,
    this.callId,
    this.isCaller = true,
    this.pendingSignals,
    Key? key,
  }) : super(key: key);

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage>
    with SingleTickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  // estados UI
  bool _muted = false;
  bool _inCall = false;
  bool _peerOfflineShown = false; // Evitar múltiples mensajes

  // ringing visual
  bool _ringing = false;
  bool _noAnswer = false;
  Timer? _ringTimeoutTimer;
  Timer? _connectionTimeoutTimer; // Nuevo: timeout para conexión WebRTC

  // pulsing animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      // Servidores STUN públicos
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},

      // Servidores TURN públicos (mejoran conectividad en NAT restrictivo)
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  @override
  void initState() {
    super.initState();

    try {
      print('📞 [CallPage] *** INIT STATE *** INICIANDO');
      print(
        '📞 [CallPage] *** PARAMS *** myUserId: ${widget.myUserId}, otherUserId: ${widget.otherUserId}',
      );
      print(
        '📞 [CallPage] *** PARAMS *** callId: ${widget.callId}, isCaller: ${widget.isCaller}',
      );
      print(
        '📞 [CallPage] *** PARAMS *** pendingSignals: ${widget.pendingSignals?.length ?? 0}',
      );

      _pulseController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      );
      _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
      );

      print('📞 [CallPage] *** INICIANDO RENDERERS ***');
      _initRenderers().catchError((e) {
        print('❌ [CallPage] *** ERROR EN RENDERERS *** $e');
      });

      print('📞 [CallPage] *** CONECTANDO SIGNALING ***');
      _connectSignalingSafe();

      print('📞 [CallPage] *** INICIANDO MEDIA Y PEER ***');
      _startLocalMediaAndPeer().catchError((e) {
        print('❌ [CallPage] *** ERROR EN MEDIA/PEER *** $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error iniciando llamada: $e')),
          );
        }
      });

      if (widget.isCaller) {
        print('📞 [CallPage] *** SOY CALLER - INICIANDO RINGING ***');
        _startRinging();
      } else {
        print('📞 [CallPage] *** SOY RECEIVER - NO RINGING ***');
      }

      print('📞 [CallPage] *** INIT STATE COMPLETADO ***');
    } catch (e, stackTrace) {
      print('❌ [CallPage] *** CRASH EN INIT STATE *** $e');
      print('❌ [CallPage] *** STACK TRACE *** $stackTrace');

      // Intentar navegar de vuelta si hay un crash crítico
      if (mounted) {
        Future.delayed(Duration(milliseconds: 100), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    }
  }

  void _processPendingSignals() {
    if (widget.pendingSignals != null && widget.pendingSignals!.isNotEmpty) {
      print(
        'CallPage: Processing ${widget.pendingSignals!.length} pending WebRTC signals',
      );

      // Procesar señales después de un pequeño delay para asegurar que todo esté inicializado
      Future.delayed(Duration(milliseconds: 500), () {
        for (final signal in widget.pendingSignals!) {
          _onSignal(signal);
        }
      });
    }
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  // intentar conectar señalización pero no bloquear el UI si falla
  void _connectSignalingSafe() {
    try {
      // IMPORTANTE: Configurar callbacks ANTES de verificar conexión
      SignalingService.instance.onSignal = _onSignal;
      SignalingService.instance.onError = (err) {
        print('CallPage: Signaling error: $err');
      };

      // Solo conectar si no hay conexión existente
      final url = baseUrl;
      if (url.isNotEmpty) {
        if (!SignalingService.instance.isConnected) {
          SignalingService.instance.connect(url, widget.myUserId);
        }
      }
    } catch (e) {
      print('CallPage: Connection failed: $e');
    }
  }

  Future<void> _startLocalMediaAndPeer() async {
    try {
      print('🎤 [CallPage] *** INICIANDO LOCAL MEDIA ***');
      print('🎤 [CallPage] *** SOLICITANDO PERMISOS DE CÁMARA/MICRÓFONO ***');

      final Map<String, dynamic> mediaConstraints = {
        'audio': true,
        'video': {'facingMode': 'user'},
      };

      print(
        '🎤 [CallPage] *** OBTENIENDO USER MEDIA *** con constraints: $mediaConstraints',
      );

      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      if (_localStream == null) {
        throw Exception('Local stream es null después de getUserMedia');
      }

      print(
        '🎤 [CallPage] *** LOCAL STREAM OBTENIDO *** tracks: ${_localStream!.getTracks().length}',
      );

      if (mounted) {
        _localRenderer.srcObject = _localStream;
        print('🎤 [CallPage] *** LOCAL RENDERER CONFIGURADO ***');
      }

      print('🔗 [CallPage] *** CREANDO PEER CONNECTION ***');
      _pc = await createPeerConnection(_iceServers, {});

      if (_pc == null) {
        throw Exception(
          'Peer connection es null después de createPeerConnection',
        );
      }

      print('🔗 [CallPage] *** AGREGANDO TRACKS AL PEER ***');
      _localStream?.getTracks().forEach((t) {
        try {
          print('🔗 [CallPage] *** AGREGANDO TRACK *** ${t.kind}: ${t.id}');
          _pc?.addTrack(t, _localStream!);
        } catch (e) {
          print('❌ [CallPage] *** ERROR AGREGANDO TRACK *** $e');
        }
      });

      print(
        '🎤 [CallPage] *** LOCAL MEDIA Y PEER CONFIGURADOS EXITOSAMENTE ***',
      );

      _pc?.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          setState(() {
            _remoteRenderer.srcObject = event.streams[0];
          });
        }
      };

      _pc?.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          try {
            SignalingService.instance
                .sendWebRTCSignal(widget.otherUserId, 'ice', {
                  'candidate': candidate.candidate,
                  'sdpMid': candidate.sdpMid,
                  'sdpMLineIndex': candidate.sdpMLineIndex,
                });
          } catch (e) {
            print('CallPage: sendWebRTCSignal(ice) failed: $e');
          }
        }
      };

      // Timeout para detectar conexiones que se quedan colgadas
      _connectionTimeoutTimer = Timer(Duration(seconds: 30), () {
        if (mounted && !_inCall) {
          print('CallPage: Connection TIMEOUT after 30 seconds! ⏰');
          print('CallPage: This usually indicates ICE/NAT issues');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Timeout de conexión. Problemas de red.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      });

      _pc?.onIceConnectionState = (RTCIceConnectionState state) {
        print('🧊 [CallPage] *** ICE CONNECTION STATE *** $state');

        switch (state) {
          case RTCIceConnectionState.RTCIceConnectionStateConnected:
            print(
              '🧊 [CallPage] *** ICE CONNECTED *** Conexión ICE establecida exitosamente! 🎉',
            );
            break;
          case RTCIceConnectionState.RTCIceConnectionStateFailed:
            print('🧊 [CallPage] *** ICE FAILED *** Conexión ICE falló! ❌');
            _printDiagnosticInfo();
            break;
          case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
            print(
              '🧊 [CallPage] *** ICE DISCONNECTED *** Conexión ICE desconectada! 📡',
            );
            break;
          case RTCIceConnectionState.RTCIceConnectionStateClosed:
            print('🧊 [CallPage] *** ICE CLOSED *** Conexión ICE cerrada! 🔒');
            break;
          case RTCIceConnectionState.RTCIceConnectionStateChecking:
            print(
              '🧊 [CallPage] *** ICE CHECKING *** Verificando conectividad ICE...',
            );
            break;
          case RTCIceConnectionState.RTCIceConnectionStateCompleted:
            print(
              '🧊 [CallPage] *** ICE COMPLETED *** Verificación ICE completada!',
            );
            break;
          case RTCIceConnectionState.RTCIceConnectionStateNew:
            print(
              '🧊 [CallPage] *** ICE NEW *** Nueva conexión ICE inicializada',
            );
            break;
          default:
            print(
              '🧊 [CallPage] *** ICE UNKNOWN *** Estado ICE desconocido: $state',
            );
        }
      };

      _pc?.onConnectionState = (RTCPeerConnectionState state) {
        print('🔗 [CallPage] *** WEBRTC CONNECTION STATE *** $state');

        if (mounted) {
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
            print(
              '🔗 [CallPage] *** WEBRTC CONNECTED *** Conexión WebRTC establecida! 🎉',
            );
            _connectionTimeoutTimer?.cancel(); // Cancelar timeout
            _stopRinging();
            setState(() => _inCall = true);
          } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
            print(
              '🔗 [CallPage] *** WEBRTC CONNECTING *** Estableciendo conexión WebRTC...',
            );
          } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            print(
              '🔗 [CallPage] *** WEBRTC DISCONNECTED *** Conexión WebRTC desconectada! 📡',
            );
            _endLocalCall();
          } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            print(
              '🔗 [CallPage] *** WEBRTC FAILED *** Conexión WebRTC falló! ❌',
            );
            _endLocalCall();
          } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
            print(
              '🔗 [CallPage] *** WEBRTC CLOSED *** Conexión WebRTC cerrada! 🔒',
            );
            _endLocalCall();
          } else {
            print('🔗 [CallPage] *** WEBRTC OTHER *** Estado: $state');
          }
        } else {
          print(
            '🔗 [CallPage] *** WEBRTC STATE CHANGE *** Widget no montado, ignorando estado: $state',
          );
        }
      };

      if (widget.isCaller) {
        // crear offer si la señalización está disponible; si no, seguimos en modo visual.
        try {
          print(
            'CallPage: 📤 Creando y enviando OFFER a ${widget.otherUserId}',
          );
          print(
            'CallPage: 🔍 PeerConnection state antes del offer: ${_pc?.connectionState}',
          );
          print(
            'CallPage: 🔍 Signaling state antes del offer: ${_pc?.signalingState}',
          );
          final offer = await _pc!.createOffer();
          print('CallPage: 🔧 Setting local description (offer)...');
          await _pc!.setLocalDescription(offer);
          print(
            'CallPage: ✅ Local description set, SDP length: ${offer.sdp?.length ?? 0}',
          );
          print(
            'CallPage: 📄 Offer SDP preview: ${offer.sdp?.substring(0, 100)}...',
          );
          print(
            'CallPage: 🔍 Signaling state después del offer: ${_pc?.signalingState}',
          );
          SignalingService.instance.sendWebRTCSignal(
            widget.otherUserId,
            'offer',
            {'sdp': offer.sdp, 'type': offer.type},
          );
          print('CallPage: 📤 OFFER enviado via SignalingService');
        } catch (e) {
          print('CallPage: ❌ createOffer failed: $e');
          print('CallPage: ❌ Stack trace: ${StackTrace.current}');
        }
      }

      // IMPORTANTE: Procesar señales pendientes DESPUÉS de que WebRTC esté listo
      _processPendingSignals();
    } catch (e, stackTrace) {
      print('❌ [CallPage] *** ERROR CRÍTICO EN LOCAL MEDIA *** $e');
      print('❌ [CallPage] *** STACK TRACE *** $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error de permisos o cámara: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );

        // Dar tiempo para mostrar el error antes de cerrar
        await Future.delayed(Duration(seconds: 1));

        if (mounted) {
          print('❌ [CallPage] *** CERRANDO CALLPAGE POR ERROR CRÍTICO ***');
          Navigator.of(context).pop();
        }
      }
    }
  }

  void _printDiagnosticInfo() {
    print('🔍 DIAGNOSTIC INFO:');
    print('- Device: ${widget.isCaller ? "CALLER" : "RECEIVER"}');
    print('- My ID: ${widget.myUserId}');
    print('- Other ID: ${widget.otherUserId}');
    print('- In Call: $_inCall');
    print('- Local Stream: ${_localStream != null}');
    print('- Peer Connection: ${_pc != null}');
    print('- ICE Servers configured: ${_iceServers["iceServers"].length}');
    print('💡 Common issues:');
    print('  - Firewall blocking UDP ports');
    print('  - Restrictive NAT/Router');
    print('  - Mobile data vs WiFi differences');
    print('  - Corporate network blocking WebRTC');
  }

  // --- RINGING visual ---
  void _startRinging() {
    _noAnswer = false;
    _ringing = true;
    _pulseController.repeat();
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        _stopRinging();
        setState(() => _noAnswer = true);
      }
    });
    if (mounted) setState(() {});
  }

  void _stopRinging() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
    try {
      _pulseController.stop();
      _pulseController.reset();
    } catch (_) {}
    _ringing = false;
    if (mounted) setState(() {});
  }

  // útiles para demo: simular respuesta -> pasar a estado 'en llamada'
  void _simulateAnswer() {
    _stopRinging();
    if (mounted) setState(() => _inCall = true);
  }

  // --- Señalización entrante ---
  Future<void> _onSignal(Map<String, dynamic> msg) async {
    print('CallPage: 📨 Señal recibida: $msg');
    final type = msg['type'] ?? msg['Type'] ?? msg['event'];
    final data = msg['payload'] ?? msg['data'] ?? msg;

    print('CallPage: 🔍 Procesando tipo: $type');

    switch (type) {
      case 'offer':
        {
          print('CallPage: 📞 Recibiendo OFFER de ${msg['from'] ?? 'unknown'}');
          print('CallPage: 🔍 PeerConnection state: ${_pc?.connectionState}');
          print('CallPage: 🔍 Signaling state: ${_pc?.signalingState}');
          if (_pc == null) {
            print('CallPage: ❌ Peer connection not ready, skipping offer');
            return;
          }
          final sdp = data['sdp'];
          final t = data['type'] ?? 'offer';
          print('CallPage: 📄 SDP length: ${sdp?.length ?? 0}');
          print('CallPage: 📄 SDP preview: ${sdp?.substring(0, 100)}...');
          final remote = RTCSessionDescription(sdp, t);
          _stopRinging();
          try {
            print('CallPage: 🔧 Setting remote description...');
            await _pc!.setRemoteDescription(remote);
            print('CallPage: ✅ Remote description set successfully');
            print('CallPage: 🔧 Creating answer...');
            final answer = await _pc!.createAnswer();
            print('CallPage: 🔧 Setting local description...');
            await _pc!.setLocalDescription(answer);
            print('CallPage: ✅ Local description set, answer ready');
            print('CallPage: 📤 Enviando ANSWER a ${widget.otherUserId}');
            SignalingService.instance.sendWebRTCSignal(
              widget.otherUserId,
              'answer',
              {'sdp': answer.sdp, 'type': answer.type},
            );
            print('CallPage: ✅ ANSWER enviado exitosamente');
          } catch (e) {
            print('CallPage: ❌ handle offer failed: $e');
            print('CallPage: ❌ Stack trace: ${StackTrace.current}');
          }
          break;
        }
      case 'answer':
        {
          print(
            'CallPage: 📞 Recibiendo ANSWER de ${msg['from'] ?? widget.otherUserId}',
          );
          print('CallPage: 🔍 PeerConnection state: ${_pc?.connectionState}');
          print('CallPage: 🔍 Signaling state: ${_pc?.signalingState}');
          if (_pc == null) {
            print('CallPage: ❌ Peer connection not ready, skipping answer');
            return;
          }
          _stopRinging();
          final sdp = data['sdp'];
          final t = data['type'] ?? 'answer';
          print('CallPage: 📄 Answer SDP length: ${sdp?.length ?? 0}');
          print(
            'CallPage: 📄 Answer SDP preview: ${sdp?.substring(0, 100)}...',
          );
          final remote = RTCSessionDescription(sdp, t);
          try {
            print('CallPage: 🔧 Setting remote description (answer)...');
            await _pc!.setRemoteDescription(remote);
            print('CallPage: ✅ Answer remote description set successfully');
            print('CallPage: 🔍 Final signaling state: ${_pc?.signalingState}');
          } catch (e) {
            print('CallPage: ❌ handle answer failed: $e');
            print('CallPage: ❌ Stack trace: ${StackTrace.current}');
          }
          break;
        }
      case 'ice':
        {
          print(
            'CallPage: 🧊 Recibiendo ICE candidate de ${msg['from'] ?? 'unknown'}',
          );
          print('CallPage: 🔍 PeerConnection state: ${_pc?.connectionState}');
          print(
            'CallPage: 🔍 ICE connection state: ${_pc?.iceConnectionState}',
          );
          if (_pc == null) {
            print('CallPage: ❌ Peer connection not ready for ICE, skipping');
            return;
          }
          final c = data['candidate'] ?? data;
          if (c != null) {
            final candidateStr = c is Map ? (c['candidate'] ?? c['cand']) : c;
            final sdpMid = c is Map ? c['sdpMid'] : null;
            final sdpMLineIndex = c is Map ? c['sdpMLineIndex'] : null;

            print(
              'CallPage: 🧊 Candidate: ${candidateStr?.toString().substring(0, 50)}...',
            );
            print(
              'CallPage: 🧊 sdpMid: $sdpMid, sdpMLineIndex: $sdpMLineIndex',
            );

            // Validar que candidate no sea null o vacío
            if (candidateStr == null ||
                candidateStr.toString().trim().isEmpty) {
              print('CallPage: ❌ Invalid candidate, skipping');
              break;
            }

            final candidate = RTCIceCandidate(
              candidateStr.toString(),
              sdpMid?.toString(),
              sdpMLineIndex,
            );
            try {
              print('CallPage: 🔧 Adding ICE candidate...');
              await _pc!.addCandidate(candidate);
              print('CallPage: ✅ ICE candidate added successfully');
            } catch (e) {
              print('CallPage: ❌ addCandidate error: $e');
            }
          }
          break;
        }
      case 'end':
        {
          _hangUp();
          break;
        }
      case 'peer-offline':
        {
          final userId = msg['to'] ?? msg['userId'];
          print('CallPage: User $userId is offline - cannot establish call');

          // Solo mostrar mensaje una vez
          if (!_peerOfflineShown && mounted) {
            _peerOfflineShown = true;

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('El usuario no está disponible'),
                duration: Duration(seconds: 3),
                action: SnackBarAction(
                  label: 'OK',
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  },
                ),
              ),
            );

            // Auto-cerrar la llamada después de 2 segundos
            Timer(Duration(seconds: 2), () {
              if (mounted) {
                _hangUp();
              }
            });
          }
          break;
        }
      default:
        {
          print('CallPage: Unknown signal - type: $type, full data: $msg');
          break;
        }
    }
  }

  Future<void> _toggleMute() async {
    if (_localStream == null) return;
    for (var t in _localStream!.getAudioTracks()) t.enabled = !t.enabled;
    if (mounted) setState(() => _muted = !_muted);
  }

  Future<void> _hangUp() async {
    print('📞 [CallPage] *** HANG UP INICIADO *** Usuario colgó la llamada');
    print(
      '📞 [CallPage] *** HANG UP *** callId: ${widget.callId}, otherUserId: ${widget.otherUserId}',
    );

    try {
      print(
        '📞 [CallPage] *** HANG UP *** Enviando señal "end" al otro usuario',
      );
      SignalingService.instance.sendSignal(widget.otherUserId, 'end', {
        'callId': widget.callId,
      });
    } catch (e) {
      print('📞 [CallPage] *** HANG UP *** Error enviando señal end: $e');
    }

    if (widget.callId != null && widget.callId!.isNotEmpty) {
      try {
        print(
          '📞 [CallPage] *** HANG UP *** Enviando endCallRequest al servidor',
        );
        await endCallRequest(widget.callId!);
      } catch (e) {
        print('📞 [CallPage] *** HANG UP *** endCallRequest error: $e');
      }
    }

    print(
      '📞 [CallPage] *** HANG UP *** Deteniendo ringing y terminando llamada local',
    );
    _stopRinging();
    _endLocalCall();

    if (mounted) {
      print('📞 [CallPage] *** HANG UP *** Navegando de vuelta (pop)');
      Navigator.of(context).pop();
    } else {
      print(
        '📞 [CallPage] *** HANG UP *** Widget no montado, no se puede navegar',
      );
    }
  }

  void _endLocalCall() {
    try {
      _pc?.close();
      _pc = null;
      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream = null;
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      if (mounted) {
        setState(() {
          _inCall = false;
        });
      }
    } catch (e) {
      print('endLocalCall error: $e');
    }
  }

  void _cleanupResources() {
    try {
      // Limpiar callbacks antes de cerrar
      if (_pc != null) {
        _pc!.onConnectionState = null;
        _pc!.onIceCandidate = null;
        _pc!.onAddStream = null;
        _pc!.onRemoveStream = null;
      }

      _pc?.close();
      _pc = null;
      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream = null;
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      _inCall = false; // Sin setState, solo cambiar el valor
    } catch (e) {
      print('cleanupResources error: $e');
    }
  }

  @override
  void dispose() {
    print('📞 [CallPage] *** DISPOSE INICIADO *** Cerrando CallPage');
    print(
      '📞 [CallPage] *** DISPOSE *** _inCall: $_inCall, _ringing: $_ringing',
    );
    print('📞 [CallPage] *** DISPOSE *** Limpiando recursos...');

    SignalingService.instance.onSignal = null;
    SignalingService.instance.dispose();
    _ringTimeoutTimer?.cancel();
    _connectionTimeoutTimer?.cancel(); // Cancelar timeout de conexión
    _pulseController.dispose();

    print('📞 [CallPage] *** DISPOSE *** Limpiando recursos WebRTC...');
    _cleanupResources(); // Usar método sin setState

    _localRenderer.dispose();
    _remoteRenderer.dispose();

    print('📞 [CallPage] *** DISPOSE COMPLETADO ***');
    super.dispose();
  }

  Widget _buildPulse() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, child) {
        final v = _pulseAnim.value;
        final size = 140.0 + (v * 60);
        final opacity = (1.0 - v).clamp(0.0, 1.0);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Opacity(
              opacity: opacity,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green.withOpacity(0.30),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    String statusText;
    if (_inCall)
      statusText = 'En llamada';
    else if (_ringing)
      statusText = 'Llamando...';
    else if (_noAnswer)
      statusText = 'Sin respuesta';
    else
      statusText = 'Conectando...';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.otherUserId),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _hangUp,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
                if (_ringing) _buildPulse(),
                Positioned(
                  right: 16,
                  top: 16,
                  width: 120,
                  height: 160,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white54),
                    ),
                    child: RTCVideoView(_localRenderer, mirror: true),
                  ),
                ),
                Positioned(
                  left: 16,
                  top: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      statusText,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FloatingActionButton(
                  heroTag: 'mute',
                  onPressed: _toggleMute,
                  backgroundColor: _muted ? Colors.orange : Colors.blue,
                  child: Icon(_muted ? Icons.mic_off : Icons.mic),
                ),
                const SizedBox(width: 24),
                FloatingActionButton(
                  heroTag: 'hangup',
                  onPressed: _hangUp,
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end),
                ),
                const SizedBox(width: 12),
                if (kDebugMode)
                  ElevatedButton(
                    onPressed: _simulateAnswer,
                    child: const Text('Simular respuesta'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
