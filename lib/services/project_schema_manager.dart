import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/project_schema.dart';

class ProjectSchemaManager {
  static final ProjectSchemaManager _instance =
      ProjectSchemaManager._internal();
  factory ProjectSchemaManager() => _instance;
  ProjectSchemaManager._internal();

  static const String _schemaFileName = 'current_schema.json';

  ProjectSchema? _activeSchema;
  ProjectSchema? get activeSchema => _activeSchema;

  /// Inicializa cargando unicamente el ultimo contrato sincronizado.
  Future<void> initialize() async {
    try {
      final file = await _getLocalFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          _activeSchema = ProjectSchema.fromJson(decoded);
          debugPrint(
            'Esquema cargado desde memoria interna: ${_activeSchema!.projectName}',
          );
          return;
        }
      }
    } catch (e) {
      debugPrint('Error leyendo esquema local: $e');
    }

    _activeSchema = null;
  }

  /// Guarda el esquema actual permanentemente en el disco del celular
  Future<void> saveCurrentSchema(ProjectSchema schema) async {
    try {
      _activeSchema = schema;
      final file = await _getLocalFile();
      await file.writeAsString(jsonEncode(schema.toJson()));
      debugPrint('Esquema guardado exitosamente en ${file.path}');
    } catch (e) {
      debugPrint('Error guardando esquema local: $e');
    }
  }

  /// Sincroniza el esquema llamando al endpoint de Spring Boot local (GET /api/schema o /v3/api-docs)
  Future<bool> fetchFromLocalBackend(String baseUrl) async {
    final cleanUrl = baseUrl.trim().endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl.trim();

    // 1. Intentar endpoint directo /api/schema
    try {
      final uri = Uri.parse('$cleanUrl/api/schema');
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          final schema = ProjectSchema.fromJson(decoded);
          if (schema.entities.isNotEmpty) {
            await saveCurrentSchema(schema);
            return true;
          }
        }
      }
    } catch (_) {}

    // 2. Intentar endpoint OpenAPI /v3/api-docs de Spring Boot
    try {
      final uri = Uri.parse('$cleanUrl/v3/api-docs');
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          final schema = _parseOpenApiToSchema(decoded);
          if (schema.entities.isNotEmpty) {
            await saveCurrentSchema(schema);
            return true;
          }
        }
      }
    } catch (_) {}

    return false;
  }

  /// Convierte la especificación OpenAPI de Spring Boot en un ProjectSchema dinámico
  ProjectSchema _parseOpenApiToSchema(Map<String, dynamic> openApi) {
    final title =
        openApi['info']?['title']?.toString() ?? 'Backend Spring Boot';
    final components =
        openApi['components']?['schemas'] as Map<String, dynamic>? ?? {};
    final List<SchemaEntity> entities = [];

    components.forEach((name, def) {
      if (def is Map<String, dynamic>) {
        final properties = def['properties'] as Map<String, dynamic>? ?? {};
        final List<EntityField> fields = [];

        properties.forEach((fieldName, propDef) {
          if (fieldName != 'id') {
            final type = propDef is Map
                ? propDef['type']?.toString() ?? 'string'
                : 'string';
            fields.add(EntityField.fromJson(fieldName, type));
          }
        });

        if (fields.isNotEmpty) {
          entities.add(
            SchemaEntity(
              name: name,
              endpoint: '/api/${name.toLowerCase()}s',
              fields: fields,
            ),
          );
        }
      }
    });

    return ProjectSchema(projectName: title, entities: entities);
  }

  Future<File> _getLocalFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_schemaFileName');
  }

  /// Retorna el catálogo NLU actual para inyectar en el prompt de Qwen 2.5
  String getActiveActionCatalog() {
    return _activeSchema?.toNluActionCatalog() ?? '';
  }
}
