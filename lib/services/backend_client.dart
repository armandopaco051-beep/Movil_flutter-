import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'project_schema_manager.dart';

class BackendResponse {
  final int statusCode;
  final String method;
  final String endpoint;
  final dynamic body;
  final bool isSuccess;
  final String message;

  BackendResponse({
    required this.statusCode,
    required this.method,
    required this.endpoint,
    required this.body,
    required this.isSuccess,
    required this.message,
  });

  factory BackendResponse.error({
    required String method,
    required String endpoint,
    required String error,
    int statusCode = 500,
  }) {
    return BackendResponse(
      statusCode: statusCode,
      method: method,
      endpoint: endpoint,
      body: {'error': error},
      isSuccess: false,
      message: 'Fallo de conexión o servidor: $error',
    );
  }
}

class BackendClient {
  static final BackendClient _instance = BackendClient._internal();
  factory BackendClient() => _instance;
  BackendClient._internal();

  static const String _settingsFileName = 'backend_settings.json';
  static const String _defaultBaseUrl = 'http://localhost:8086';

  String _baseUrl = _defaultBaseUrl;

  String get baseUrl => _baseUrl;
  set baseUrl(String url) {
    _baseUrl = _normalizeBaseUrl(url);
  }

  Future<void> initialize() async {
    try {
      final file = await _getSettingsFile();
      if (!await file.exists()) return;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        final savedUrl = decoded['baseUrl']?.toString();
        if (savedUrl != null && savedUrl.trim().isNotEmpty) {
          _baseUrl = _normalizeBaseUrl(savedUrl);
        }
      }
    } catch (_) {
      _baseUrl = _defaultBaseUrl;
    }
  }

  Future<void> configureBaseUrl(String url) async {
    _baseUrl = _normalizeBaseUrl(url);
    final file = await _getSettingsFile();
    await file.writeAsString(jsonEncode({'baseUrl': _baseUrl}));
  }

  Future<BackendResponse> checkHealth() {
    return _sendGet('/api/health');
  }

  /// Despachador Universal: resuelve verbo y entidad dinámicamente según el esquema activo
  Future<BackendResponse> dispatchAction({
    required String action,
    required Map<String, dynamic> data,
  }) async {
    final cleanAction = action.toUpperCase().trim();
    final parts = cleanAction.split('_');

    if (parts.isEmpty) {
      return BackendResponse.error(
        method: 'UNKNOWN',
        endpoint: '/api',
        error: 'Acción vacía',
        statusCode: 400,
      );
    }

    final rawVerb = parts.first;
    final rawEntity = parts.length > 1 ? parts.sublist(1).join('_') : 'GENERAL';

    // 1. Resolver el endpoint dinámicamente según el esquema cargado
    final endpoint = _resolveEndpoint(rawEntity);
    if (endpoint == null) {
      return BackendResponse.error(
        method: 'UNKNOWN',
        endpoint: '/api',
        error: 'La entidad "$rawEntity" no existe en el esquema activo',
        statusCode: 400,
      );
    }

    // 2. Ejecutar según el verbo estándar
    if (rawVerb == 'CREAR' ||
        rawVerb == 'REGISTRAR' ||
        rawVerb == 'AGREGAR' ||
        rawVerb == 'INSERTAR') {
      return _sendPost(endpoint, data);
    } else if (rawVerb == 'LISTAR' ||
        rawVerb == 'CONSULTAR' ||
        rawVerb == 'OBTENER' ||
        rawVerb == 'VER') {
      final id =
          data['id'] ?? data['${rawEntity.toLowerCase()}_id'] ?? data['codigo'];
      return _sendGet(id == null ? endpoint : '$endpoint/$id');
    } else if (rawVerb == 'ELIMINAR' ||
        rawVerb == 'BORRAR' ||
        rawVerb == 'CANCELAR') {
      final id =
          data['id'] ?? data['${rawEntity.toLowerCase()}_id'] ?? data['codigo'];
      if (id == null) {
        return BackendResponse.error(
          method: 'DELETE',
          endpoint: '$endpoint/{id}',
          error:
              'Falta el identificador (id) para eliminar el registro de $rawEntity',
          statusCode: 400,
        );
      }
      return _sendDelete('$endpoint/$id');
    } else if (rawVerb == 'ACTUALIZAR' ||
        rawVerb == 'MODIFICAR' ||
        rawVerb == 'EDITAR') {
      final id =
          data['id'] ?? data['${rawEntity.toLowerCase()}_id'] ?? data['codigo'];
      if (id == null) {
        return BackendResponse.error(
          method: 'PUT',
          endpoint: '$endpoint/{id}',
          error:
              'Falta el identificador (id) para actualizar el registro de $rawEntity',
          statusCode: 400,
        );
      }
      return _sendPut('$endpoint/$id', data);
    }

    // Si la acción no tiene verbo reconocido pero es una consulta genérica
    return BackendResponse.error(
      method: 'DESCONOCIDO',
      endpoint: endpoint,
      error:
          'Acción "$action" no contiene un verbo CRUD válido (CREAR, LISTAR, ELIMINAR, ACTUALIZAR)',
      statusCode: 400,
    );
  }

  /// Busca el endpoint exacto en el esquema del proyecto o aplica pluralización inteligente
  String? _resolveEndpoint(String entityName) {
    final activeSchema = ProjectSchemaManager().activeSchema;
    if (activeSchema != null) {
      for (final entity in activeSchema.entities) {
        final cleanSchemaEntity = entity.name
            .replaceAll(' ', '_')
            .toUpperCase();
        if (cleanSchemaEntity == entityName ||
            cleanSchemaEntity.contains(entityName) ||
            entityName.contains(cleanSchemaEntity)) {
          return entity.endpoint;
        }
      }

      return null;
    }

    // Pluralización por defecto en caso de no estar en el esquema
    return '/api/${_pluralize(entityName.toLowerCase())}';
  }

  Future<BackendResponse> _sendPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 4));

      return _buildResponse('POST', path, response);
    } catch (e) {
      return BackendResponse.error(
        method: 'POST',
        endpoint: path,
        error: e.toString(),
      );
    }
  }

  Future<BackendResponse> _sendGet(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 4));

      return _buildResponse('GET', path, response);
    } catch (e) {
      return BackendResponse.error(
        method: 'GET',
        endpoint: path,
        error: e.toString(),
      );
    }
  }

  Future<BackendResponse> _sendPut(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await http
          .put(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 4));

      return _buildResponse('PUT', path, response);
    } catch (e) {
      return BackendResponse.error(
        method: 'PUT',
        endpoint: path,
        error: e.toString(),
      );
    }
  }

  Future<BackendResponse> _sendDelete(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await http
          .delete(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 4));

      return _buildResponse('DELETE', path, response);
    } catch (e) {
      return BackendResponse.error(
        method: 'DELETE',
        endpoint: path,
        error: e.toString(),
      );
    }
  }

  BackendResponse _buildResponse(
    String method,
    String endpoint,
    http.Response response,
  ) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = response.body;
    }

    final isOk = response.statusCode >= 200 && response.statusCode < 300;
    return BackendResponse(
      statusCode: response.statusCode,
      method: method,
      endpoint: endpoint,
      body: decoded,
      isSuccess: isOk,
      message: isOk
          ? 'Éxito ($method $endpoint - ${response.statusCode})'
          : 'Respuesta Spring Boot ($method $endpoint - ${response.statusCode})',
    );
  }

  String _pluralize(String word) {
    if (word.endsWith('s')) return word;
    if (word.endsWith('r') ||
        word.endsWith('l') ||
        word.endsWith('n') ||
        word.endsWith('d')) {
      return '${word}es';
    }
    return '${word}s';
  }

  String _normalizeBaseUrl(String url) {
    var normalized = url.trim();
    if (normalized.isEmpty) return _defaultBaseUrl;
    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }
    return normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  Future<File> _getSettingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_settingsFileName');
  }
}
