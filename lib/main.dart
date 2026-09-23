import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/local_ai_service.dart';
import 'services/voice_service.dart';
import 'services/backend_client.dart';
import 'services/backend_discovery_service.dart';
import 'services/project_schema_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalAiApp());
}

class LocalAiApp extends StatelessWidget {
  const LocalAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DrawSchemaAI Mobile NLU',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF12131C),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00E676),
          surface: Color(0xFF1E1F2E),
        ),
      ),
      home: const MainConsoleScreen(),
    );
  }
}

class LogEntry {
  final DateTime timestamp;
  final String sender; // 'USER', 'IA_LOCAL', 'SPRING_BOOT', 'SISTEMA'
  final String message;
  final bool isError;
  final Map<String, dynamic>? data;

  LogEntry({
    required this.sender,
    required this.message,
    this.isError = false,
    this.data,
  }) : timestamp = DateTime.now();
}

class MainConsoleScreen extends StatefulWidget {
  const MainConsoleScreen({super.key});

  @override
  State<MainConsoleScreen> createState() => _MainConsoleScreenState();
}

class _MainConsoleScreenState extends State<MainConsoleScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final LocalAiService _aiService = LocalAiService();
  final VoiceService _voiceService = VoiceService();
  final BackendClient _backendClient = BackendClient();
  final BackendDiscoveryService _discoveryService = BackendDiscoveryService();
  final ProjectSchemaManager _schemaManager = ProjectSchemaManager();

  final List<LogEntry> _logs = [];
  bool _isProcessing = false;
  bool _isRecordingVoice = false;
  bool _backendConnected = false;
  bool _isDiscovering = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    _addLog('SISTEMA', 'Iniciando DrawSchemaAI Mobile...');

    // 1. Cargar configuracion y ultimo esquema disponible.
    await _backendClient.initialize();
    await _schemaManager.initialize();

    // 2. Probar la ultima URL y, si ya no responde, buscar el backend en Wi-Fi.
    final health = await _backendClient.checkHealth();
    if (health.isSuccess) {
      _backendConnected = await _schemaManager.fetchFromLocalBackend(
        _backendClient.baseUrl,
      );
      if (_backendConnected) {
        _addLog(
          'SISTEMA',
          'Backend detectado y esquema sincronizado desde ${_backendClient.baseUrl}.',
        );
      } else {
        _addLog(
          'SISTEMA',
          'El backend responde, pero no entregó un esquema válido en /api/schema.',
          isError: true,
        );
      }
    } else {
      _addLog(
        'SISTEMA',
        'La última URL no responde. Buscando backends DrawSchema en la red local...',
      );
      await _discoverAndConnect(reportWhenEmpty: true);
    }

    final projectName =
        _schemaManager.activeSchema?.projectName ?? 'Sin Proyecto';
    final entities =
        _schemaManager.activeSchema?.entities.map((e) => e.name).join(', ') ??
        '';
    _addLog(
      'SISTEMA',
      '📁 Proyecto activo: $projectName\nEntidades disponibles: [$entities]',
    );

    // 3. Inicializar IA local. El microfono se solicita solo al pulsarlo.
    final aiOk = await _aiService.initialize();
    if (aiOk) {
      _addLog('IA_LOCAL', 'Motor Qwen 2.5 0.5B cargado y listo');
    } else {
      _addLog(
        'IA_LOCAL',
        _aiService.statusMessage,
        isError: !_aiService.isInitialized,
      );
      _addLog(
        'SISTEMA',
        'Modo heurístico activo mientras se coloca el modelo GGUF.',
      );
    }
  }

  void _addLog(
    String sender,
    String message, {
    bool isError = false,
    Map<String, dynamic>? data,
  }) {
    if (!mounted) return;
    setState(() {
      _logs.add(
        LogEntry(
          sender: sender,
          message: message,
          isError: isError,
          data: data,
        ),
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleUserSubmission(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty || _isProcessing) return;

    _inputController.clear();
    setState(() => _isProcessing = true);

    // 1. Entrada de usuario
    _addLog('USER', text);

    try {
      // 2. Inferencia de la IA Local adaptada al proyecto
      _addLog(
        'SISTEMA',
        'IA Local interpretando en base a "${_schemaManager.activeSchema?.projectName}"...',
      );
      final nluResult = await _aiService.processInput(text);

      if (!nluResult.isSuccess) {
        _addLog(
          'IA_LOCAL',
          'Error en interpretación: ${nluResult.error}',
          isError: true,
        );
        setState(() => _isProcessing = false);
        return;
      }

      final action = nluResult.action;
      final datos = nluResult.data;

      if (action == 'NO_ACTION' || action == 'CONSULTA_GENERAL') {
        _addLog(
          'IA_LOCAL',
          datos['respuesta']?.toString() ??
              'Indícame qué deseas crear, listar, actualizar o eliminar.',
        );
        return;
      }

      _addLog(
        'IA_LOCAL',
        'Acción: $action\nDatos: ${const JsonEncoder.withIndent('  ').convert(datos)}',
        data: datos,
      );

      // 3. Despacho directo a Spring Boot Local
      if (!_backendConnected) {
        final health = await _backendClient.checkHealth();
        _backendConnected = health.isSuccess;
        if (!_backendConnected) {
          _addLog(
            'SISTEMA',
            'La URL guardada no responde. Buscando el backend automáticamente...',
          );
          await _discoverAndConnect(reportWhenEmpty: false);
        }
        if (!_backendConnected) {
          _addLog(
            'SISTEMA',
            'No se encontró un Spring Boot disponible. Inícialo en una computadora de la misma red o configura la URL manualmente.',
            isError: true,
          );
          return;
        }
      }

      _addLog(
        'SISTEMA',
        'Enviando petición a Spring Boot local (${_backendClient.baseUrl})...',
      );
      final backendResponse = await _backendClient.dispatchAction(
        action: action,
        data: datos,
      );

      // 4. Mostrar respuesta directa de Spring Boot / PostgreSQL
      final bodyStr =
          backendResponse.body is Map || backendResponse.body is List
          ? const JsonEncoder.withIndent('  ').convert(backendResponse.body)
          : backendResponse.body.toString();

      _addLog(
        'SPRING_BOOT',
        '${backendResponse.method} ${backendResponse.endpoint} -> Código: ${backendResponse.statusCode}\n$bodyStr',
        isError: !backendResponse.isSuccess,
      );
    } catch (e) {
      _addLog('SISTEMA', 'Fallo en el flujo: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _toggleVoice() async {
    if (_isProcessing) return;

    if (_isRecordingVoice) {
      await _voiceService.stopListening();
      setState(() => _isRecordingVoice = false);
    } else {
      final voiceOk = await _voiceService.initialize();
      if (!voiceOk) {
        _addLog(
          'SISTEMA',
          'Micrófono no disponible: ${_voiceService.lastError}',
          isError: true,
        );
        return;
      }
      setState(() => _isRecordingVoice = true);
      _addLog('SISTEMA', '🎙️ Escuchando... Dicta tu petición.');

      await _voiceService.startListening(
        onResult: (words, isFinal) {
          if (!mounted) return;
          _inputController.text = words;
          if (isFinal && words.trim().isNotEmpty) {
            setState(() => _isRecordingVoice = false);
            _handleUserSubmission(words);
          }
        },
      );
    }
  }

  /// Sincroniza las entidades llamando al endpoint del Spring Boot local
  Future<void> _syncSchemaFromLocalBackend() async {
    _addLog(
      'SISTEMA',
      'Intentando sincronizar esquema desde ${_backendClient.baseUrl}/api/schema...',
    );
    final health = await _backendClient.checkHealth();
    if (!health.isSuccess) {
      _backendConnected = false;
      _addLog(
        'SISTEMA',
        'Spring Boot no responde en ${_backendClient.baseUrl}. Revisa el puerto y que el servidor esté iniciado.',
        isError: true,
      );
      setState(() {});
      return;
    }

    final ok = await _schemaManager.fetchFromLocalBackend(
      _backendClient.baseUrl,
    );
    _backendConnected = ok;
    if (ok) {
      final pName = _schemaManager.activeSchema?.projectName ?? '';
      final entities =
          _schemaManager.activeSchema?.entities.map((e) => e.name).join(', ') ??
          '';
      _addLog(
        'SISTEMA',
        'Esquema sincronizado y guardado en el teléfono.\nProyecto: $pName\nEntidades: [$entities]',
      );
      setState(() {});
    } else {
      _addLog(
        'SISTEMA',
        'No se pudo sincronizar automáticamente desde el backend local. Verifica que Spring Boot esté corriendo o cambia de proyecto manualmente con el botón del menú.',
        isError: true,
      );
    }
  }

  Future<bool> _discoverAndConnect({required bool reportWhenEmpty}) async {
    if (_isDiscovering) return false;
    if (mounted) setState(() => _isDiscovering = true);

    try {
      final backends = await _discoveryService.discover();
      if (backends.isEmpty) {
        if (reportWhenEmpty) {
          _addLog(
            'SISTEMA',
            'No se encontraron backends DrawSchema por Wi-Fi. Se mantiene ${_backendClient.baseUrl} y el último esquema guardado.',
            isError: true,
          );
        }
        return false;
      }

      DiscoveredBackend? selected;
      if (backends.length == 1) {
        selected = backends.first;
      } else if (mounted) {
        selected = await _showBackendSelector(backends);
      }

      if (selected == null) {
        _addLog(
          'SISTEMA',
          'Se encontraron ${backends.length} backends. Selecciona uno con el botón de red.',
        );
        return false;
      }

      return await _connectToDiscoveredBackend(selected);
    } on PlatformException catch (error) {
      _addLog(
        'SISTEMA',
        'No se pudo buscar por mDNS: ${error.message ?? error.code}',
        isError: reportWhenEmpty,
      );
      return false;
    } catch (error) {
      _addLog(
        'SISTEMA',
        'Falló la búsqueda automática: $error',
        isError: reportWhenEmpty,
      );
      return false;
    } finally {
      if (mounted) setState(() => _isDiscovering = false);
    }
  }

  Future<bool> _connectToDiscoveredBackend(DiscoveredBackend backend) async {
    await _backendClient.configureBaseUrl(backend.baseUrl);
    _backendConnected = false;
    _addLog(
      'SISTEMA',
      'Backend encontrado: ${backend.project} en ${backend.baseUrl}. Validando contrato...',
    );
    await _syncSchemaFromLocalBackend();
    return _backendConnected;
  }

  Future<DiscoveredBackend?> _showBackendSelector(
    List<DiscoveredBackend> backends,
  ) {
    return showDialog<DiscoveredBackend>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F2E),
        title: const Text('Seleccionar backend local'),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: backends.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final backend = backends[index];
              return ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(backend.project),
                subtitle: Text(backend.baseUrl),
                onTap: () => Navigator.pop(ctx, backend),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  Future<void> _searchBackends() async {
    _addLog('SISTEMA', 'Buscando proyectos Spring Boot en la red local...');
    await _discoverAndConnect(reportWhenEmpty: true);
  }

  void _showBackendSettings() {
    final controller = TextEditingController(text: _backendClient.baseUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F2E),
        title: const Text('Configurar Spring Boot Local'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'La app busca el backend automáticamente. Usa esta URL solo como respaldo.\n\nEmulador: http://10.0.2.2:8086\nCable USB: http://localhost:8086',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'URL Base',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _backendClient.configureBaseUrl(controller.text);
              _backendConnected = false;
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _addLog(
                'SISTEMA',
                'URL guardada: ${_backendClient.baseUrl}. Comprobando conexión...',
              );
              await _syncSchemaFromLocalBackend();
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final projectName =
        _schemaManager.activeSchema?.projectName ?? 'Sin Proyecto';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1B29),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              projectName,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF00E676),
              ),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${_backendConnected ? 'Conectado' : 'Desconectado'}: ${_backendClient.baseUrl}',
              style: TextStyle(
                fontSize: 11,
                color: _backendConnected
                    ? const Color(0xFF00E676)
                    : Colors.white60,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: _isDiscovering
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find, size: 20),
            tooltip: 'Buscar backend en la red local',
            onPressed: _isDiscovering ? null : _searchBackends,
          ),
          // Sincronizar esquema con Spring Boot Local
          IconButton(
            icon: const Icon(Icons.sync_outlined, size: 20),
            tooltip: 'Sincronizar esquema con Spring Boot local',
            onPressed: _syncSchemaFromLocalBackend,
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            tooltip: 'Ajustar URL',
            onPressed: _showBackendSettings,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep, size: 20),
            tooltip: 'Limpiar consola',
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          // Consola de interacción directa
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];
                return _buildLogWidget(log);
              },
            ),
          ),

          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: Color(0xFF6C63FF),
              ),
            ),

          // Barra de entrada directa: texto + micrófono
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1F2E),
              border: Border(top: BorderSide(color: Color(0xFF2C2D3E))),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  // Botón de Micrófono
                  IconButton(
                    icon: Icon(
                      _isRecordingVoice ? Icons.mic : Icons.mic_none,
                      color: _isRecordingVoice
                          ? Colors.redAccent
                          : const Color(0xFF00E676),
                      size: 26,
                    ),
                    tooltip: 'Dictar por voz',
                    onPressed: _toggleVoice,
                  ),
                  const SizedBox(width: 4),
                  // Campo de texto directo
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      enabled: !_isProcessing,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: _isRecordingVoice
                            ? 'Escuchando voz...'
                            : 'Escribe un comando o petición...',
                        hintStyle: const TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        filled: true,
                        fillColor: const Color(0xFF12131C),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: _handleUserSubmission,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Botón enviar texto
                  IconButton(
                    icon: const Icon(
                      Icons.send_rounded,
                      color: Color(0xFF6C63FF),
                    ),
                    onPressed: _isProcessing
                        ? null
                        : () => _handleUserSubmission(_inputController.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogWidget(LogEntry log) {
    Color badgeColor;
    String badgeText;
    IconData icon;

    switch (log.sender) {
      case 'USER':
        badgeColor = const Color(0xFF3F51B5);
        badgeText = 'USUARIO';
        icon = Icons.person_outline;
        break;
      case 'IA_LOCAL':
        badgeColor = const Color(0xFF6C63FF);
        badgeText = 'IA LOCAL (QWEN)';
        icon = Icons.psychology_outlined;
        break;
      case 'SPRING_BOOT':
        badgeColor = log.isError ? Colors.redAccent : const Color(0xFF00E676);
        badgeText = 'SPRING BOOT (POSTGRES)';
        icon = Icons.storage_outlined;
        break;
      case 'SISTEMA':
      default:
        badgeColor = Colors.grey.shade600;
        badgeText = 'SISTEMA';
        icon = Icons.info_outline;
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF181926),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: log.isError
              ? Colors.redAccent.withValues(alpha: 0.5)
              : const Color(0xFF2C2D3E),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: badgeColor),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 10, color: Colors.white30),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            log.message,
            style: TextStyle(
              fontSize: 13,
              fontFamily:
                  log.sender == 'IA_LOCAL' || log.sender == 'SPRING_BOOT'
                  ? 'monospace'
                  : null,
              color: log.isError ? Colors.redAccent : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _aiService.dispose();
    super.dispose();
  }
}
