import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart';
import 'package:path_provider/path_provider.dart';

import '../core/prompts/nlu_prompt.dart';
import 'project_schema_manager.dart';

class NluResult {
  final String action;
  final Map<String, dynamic> data;
  final String rawResponse;
  final bool isSuccess;
  final String? error;

  NluResult({
    required this.action,
    required this.data,
    required this.rawResponse,
    this.isSuccess = true,
    this.error,
  });

  factory NluResult.error(String message, {String raw = ''}) {
    return NluResult(
      action: 'ERROR',
      data: {},
      rawResponse: raw,
      isSuccess: false,
      error: message,
    );
  }
}

class LocalAiService {
  static final LocalAiService _instance = LocalAiService._internal();
  factory LocalAiService() => _instance;
  LocalAiService._internal();

  static const String defaultModelFileName =
      'qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const MethodChannel _modelAssetChannel = MethodChannel(
    'drawschema.ai/model_assets',
  );

  LlamaCppChatRepository? _chatRepo;

  bool _isInitialized = false;
  bool _isLoading = false;
  String _statusMessage = 'IA no inicializada';
  String? _modelPath;

  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String get statusMessage => _statusMessage;
  String? get modelPath => _modelPath;

  /// Inicializa el motor de IA local buscando el archivo GGUF en almacenamiento local o assets
  Future<bool> initialize({String? customPath}) async {
    if (_isInitialized) return true;
    _isLoading = true;
    _statusMessage = 'Buscando modelo GGUF...';

    try {
      String resolvedPath = '';

      if (customPath != null && await File(customPath).exists()) {
        resolvedPath = customPath;
      } else {
        final docsDir = await getApplicationDocumentsDirectory();
        final localFile = File('${docsDir.path}/$defaultModelFileName');

        if (await localFile.exists()) {
          resolvedPath = localFile.path;
        } else {
          // El APK trae Qwen incluido. Android lo copia por streaming para no
          // reservar otros 491 MB de memoria durante el primer arranque.
          try {
            _statusMessage =
                'Copiando modelo desde assets a memoria interna...';
            resolvedPath = await _copyBundledModel(localFile);
          } catch (_) {
            _statusMessage =
                'El APK no contiene el modelo $defaultModelFileName.';
            _modelPath = localFile.path;
            _isLoading = false;
            return false;
          }
        }
      }

      _modelPath = resolvedPath;
      _statusMessage = 'Cargando modelo Qwen en memoria...';

      // La API de repositorio 0.7 no registra correctamente los backends
      // dinamicos en algunos Android. Esta ruta usa el inicializador Android
      // con la carpeta nativa real antes de abrir el GGUF.
      _chatRepo = LlamaCppChatRepository(
        // El catalogo dinamico puede superar 1.000 tokens. llm_llamacpp
        // evalua el prompt inicial en un solo lote, por eso n_batch debe
        // contenerlo completo para evitar un aborto nativo en llama_decode.
        contextSize: 4096,
        batchSize: 2048,
        nGpuLayers: 0,
      );
      // ignore: deprecated_member_use
      _chatRepo!.initializeBackend();
      // ignore: deprecated_member_use
      await _chatRepo!.loadModel(resolvedPath);

      _isInitialized = true;
      _statusMessage = 'IA Local lista (Qwen 2.5 0.5B)';
      _isLoading = false;
      return true;
    } catch (e, stack) {
      debugPrint('Error inicializando LlamaCpp: $e\n$stack');
      _statusMessage = 'Error al cargar modelo: $e';
      _isLoading = false;
      return false;
    }
  }

  Future<String> _copyBundledModel(File fallbackTarget) async {
    const assetPath = 'assets/models/$defaultModelFileName';

    if (Platform.isAndroid) {
      final copiedPath = await _modelAssetChannel.invokeMethod<String>(
        'copyBundledModel',
        {'asset': assetPath, 'fileName': defaultModelFileName},
      );
      if (copiedPath == null || !await File(copiedPath).exists()) {
        throw StateError('Android no pudo copiar el modelo incluido.');
      }
      return copiedPath;
    }

    final byteData = await rootBundle.load(assetPath);
    await fallbackTarget.writeAsBytes(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    return fallbackTarget.path;
  }

  /// Procesa la entrada del usuario mediante NLU y devuelve la acción y datos JSON
  Future<NluResult> processInput(
    String userInput, {
    String? customCatalog,
  }) async {
    final cleanInput = userInput.trim();
    if (cleanInput.isEmpty) {
      return NluResult.error('El texto de entrada está vacío');
    }

    if (_isGreeting(cleanInput)) {
      return _noAction(
        'Hola. Indícame qué registro deseas crear, listar, actualizar o eliminar.',
      );
    }

    final activeSchema = ProjectSchemaManager().activeSchema;
    if (activeSchema == null || activeSchema.entities.isEmpty) {
      return _noAction(
        'No hay un proyecto activo. Conecta y sincroniza un backend que exponga /api/schema.',
      );
    }

    // La IA solo recibe este texto y el contrato del proyecto activo. No se le
    // exponen herramientas para leer archivos, sensores u otros datos del equipo.
    final catalog =
        customCatalog ?? ProjectSchemaManager().getActiveActionCatalog();

    final systemPrompt = NluPrompt.buildSystem(customActionsCatalog: catalog);

    // Si el modelo aún no está cargado físicamente en el móvil, usamos fallback inteligente para desarrollo
    if (!_isInitialized || _chatRepo == null) {
      return _fallbackHeuristic(cleanInput);
    }

    try {
      final messages = [
        LLMMessage(role: LLMRole.system, content: systemPrompt),
        LLMMessage(role: LLMRole.user, content: cleanInput),
      ];

      final buffer = StringBuffer();
      final stream = _chatRepo!.streamChatWithGenerationOptions(
        'qwen2.5-0.5b',
        messages: messages,
        generationOptions: const GenerationOptions(
          temperature: 0.0,
          topP: 1.0,
          topK: 1,
          maxTokens: 128,
          seed: 42,
        ),
      );

      await for (final chunk in stream) {
        final content = chunk.message?.content ?? '';
        buffer.write(content);
      }

      final rawResponse = buffer.toString().trim();
      return _validateAction(_extractJsonFromResponse(rawResponse));
    } catch (e) {
      debugPrint('Error en inferencia LLM: $e');
      return NluResult.error('Error durante la inferencia: $e');
    }
  }

  /// Limpia la salida usando Regex estricto para extraer solo el objeto JSON
  NluResult _extractJsonFromResponse(String rawResponse) {
    try {
      final match = RegExp(r'\{.*\}', dotAll: true).firstMatch(rawResponse);
      final jsonPuro = match?.group(0) ?? '{}';
      final dynamic decoded = jsonDecode(jsonPuro);

      if (decoded is Map<String, dynamic>) {
        final action = decoded['accion']?.toString() ?? 'DESCONOCIDO';
        final data = decoded['datos'] is Map<String, dynamic>
            ? decoded['datos'] as Map<String, dynamic>
            : <String, dynamic>{};

        return NluResult(action: action, data: data, rawResponse: rawResponse);
      } else {
        return NluResult.error(
          'El formato de salida no es un objeto JSON',
          raw: rawResponse,
        );
      }
    } catch (e) {
      return NluResult.error('Error al decodificar JSON: $e', raw: rawResponse);
    }
  }

  /// Parser heurístico offline para pruebas cuando el archivo GGUF aún no fue transferido
  NluResult _fallbackHeuristic(String input) {
    final lower = input.toLowerCase();
    final schema = ProjectSchemaManager().activeSchema;

    // Detectar verbo
    String? verb;
    if (lower.contains('crear') ||
        lower.contains('crea') ||
        lower.contains('registrar') ||
        lower.contains('registra') ||
        lower.contains('agregar') ||
        lower.contains('agrega') ||
        lower.contains('insertar')) {
      verb = 'CREAR';
    } else if (lower.contains('listar') ||
        lower.contains('ver') ||
        lower.contains('consultar') ||
        lower.contains('mostrar')) {
      verb = 'LISTAR';
    } else if (lower.contains('eliminar') ||
        lower.contains('borrar') ||
        lower.contains('cancela')) {
      verb = 'ELIMINAR';
    } else if (lower.contains('actualizar') ||
        lower.contains('modificar') ||
        lower.contains('editar')) {
      verb = 'ACTUALIZAR';
    }

    // Buscar si alguna entidad del esquema coincide con el texto
    if (verb != null && schema != null && schema.entities.isNotEmpty) {
      for (final entity in schema.entities) {
        final entityLower = entity.name.toLowerCase();
        final entityUpper = entity.name.replaceAll(' ', '_').toUpperCase();

        if (lower.contains(entityLower) ||
            lower.contains(
              entityLower.substring(
                0,
                entityLower.length > 4
                    ? entityLower.length - 1
                    : entityLower.length,
              ),
            )) {
          final Map<String, dynamic> data = {};

          if (verb == 'ELIMINAR' || verb == 'ACTUALIZAR') {
            final idMatch = RegExp(r'\b\d+\b').firstMatch(lower);
            if (idMatch != null) {
              data['id'] = int.tryParse(idMatch.group(0)!);
            }
          }

          if (verb == 'CREAR' || verb == 'ACTUALIZAR') {
            for (final f in entity.fields) {
              if (f.type == 'int') {
                final match = RegExp(r'\b\d+\b').firstMatch(lower);
                if (match != null && !data.containsKey('id')) {
                  data[f.name] = int.tryParse(match.group(0)!);
                } else {
                  data[f.name] = 10;
                }
              } else if (f.type == 'double') {
                final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(lower);
                data[f.name] = match != null
                    ? double.tryParse(match.group(1)!)
                    : 25.5;
              } else {
                // String: extraer palabras clave o usar parte del texto
                final clean = input
                    .replaceAll(
                      RegExp(
                        r'\b(agrega|registra|crea|un|una|el|la)\b',
                        caseSensitive: false,
                      ),
                      '',
                    )
                    .trim();
                data[f.name] = clean.isNotEmpty ? clean : 'Dato_${f.name}';
              }
            }
          }

          final action = '${verb}_$entityUpper';
          return _validateAction(
            NluResult(
              action: action,
              data: data,
              rawResponse: jsonEncode({'accion': action, 'datos': data}),
            ),
          );
        }
      }
    }

    return _noAction(
      'No identifiqué una operación válida. Indica una acción y una entidad del proyecto.',
    );
  }

  NluResult _validateAction(NluResult result) {
    if (!result.isSuccess || result.action == 'NO_ACTION') return result;

    final schema = ProjectSchemaManager().activeSchema;
    if (schema == null || !schema.supportsAction(result.action)) {
      return _noAction(
        'La acción ${result.action} no está disponible en el proyecto activo.',
        raw: result.rawResponse,
      );
    }
    return result;
  }

  NluResult _noAction(String response, {String? raw}) {
    final data = <String, dynamic>{'respuesta': response};
    return NluResult(
      action: 'NO_ACTION',
      data: data,
      rawResponse: raw ?? jsonEncode({'accion': 'NO_ACTION', 'datos': data}),
    );
  }

  bool _isGreeting(String input) {
    return RegExp(
      r'^\s*(hola|buenas|buenos días|buenos dias|buenas tardes|buenas noches|gracias)[!,.\s]*$',
      caseSensitive: false,
    ).hasMatch(input);
  }

  void dispose() {
    _releaseModel();
  }

  void _releaseModel() {
    _chatRepo?.dispose();
    _chatRepo = null;
    _isInitialized = false;
  }
}
