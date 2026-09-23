class EntityField {
  final String name;
  final String type; // string, int, double, boolean, date
  final bool isRequired;

  EntityField({
    required this.name,
    required this.type,
    this.isRequired = false,
  });

  factory EntityField.fromJson(String name, dynamic value) {
    if (value is String) {
      return EntityField(name: name, type: _normalizeType(value));
    } else if (value is Map<String, dynamic>) {
      return EntityField(
        name: name,
        type: _normalizeType(value['type']?.toString() ?? 'string'),
        isRequired: value['required'] == true,
      );
    }
    return EntityField(name: name, type: 'string');
  }

  Map<String, dynamic> toJson() => {'type': type, 'required': isRequired};

  static String _normalizeType(String value) {
    switch (value.toLowerCase()) {
      case 'integer':
      case 'long':
        return 'int';
      case 'number':
      case 'float':
      case 'decimal':
        return 'double';
      default:
        return value.toLowerCase();
    }
  }
}

class SchemaEntity {
  static const List<String> defaultOperations = [
    'CREAR',
    'LISTAR',
    'OBTENER',
    'ACTUALIZAR',
    'ELIMINAR',
  ];

  final String name; // e.g. "Herramienta", "Jugador", "Producto"
  final String endpoint; // e.g. "/api/herramientas", "/api/jugadores"
  final List<EntityField> fields;
  final List<String> operations;

  SchemaEntity({
    required this.name,
    required this.endpoint,
    required this.fields,
    this.operations = defaultOperations,
  });

  factory SchemaEntity.fromJson(Map<String, dynamic> json) {
    final name =
        json['nombre']?.toString() ?? json['name']?.toString() ?? 'Entidad';
    final endpoint =
        json['endpoint']?.toString() ??
        '/api/${_defaultPluralize(name.toLowerCase())}';

    final rawFields =
        json['atributos'] ?? json['campos'] ?? json['fields'] ?? {};
    final rawOperations = json['operaciones'] ?? json['operations'];
    final List<EntityField> fieldsList = [];
    final operations = rawOperations is List
        ? rawOperations.map((value) => value.toString().toUpperCase()).toList()
        : List<String>.from(defaultOperations);

    if (rawFields is Map) {
      rawFields.forEach((key, val) {
        fieldsList.add(EntityField.fromJson(key.toString(), val));
      });
    } else if (rawFields is List) {
      for (final f in rawFields) {
        if (f is Map<String, dynamic>) {
          fieldsList.add(
            EntityField(
              name: f['nombre'] ?? f['name'] ?? 'campo',
              type: f['tipo'] ?? f['type'] ?? 'string',
              isRequired: f['requerido'] ?? f['required'] ?? false,
            ),
          );
        }
      }
    }

    return SchemaEntity(
      name: name,
      endpoint: endpoint,
      fields: fieldsList,
      operations: operations,
    );
  }

  Map<String, dynamic> toJson() => {
    'nombre': name,
    'endpoint': endpoint,
    'atributos': {for (var f in fields) f.name: f.toJson()},
    'operaciones': operations,
  };

  bool supports(String operation) =>
      operations.contains(operation.toUpperCase());

  static String _defaultPluralize(String word) {
    if (word.endsWith('s')) return word;
    if (word.endsWith('r') || word.endsWith('l') || word.endsWith('n')) {
      return '${word}es';
    }
    return '${word}s';
  }
}

class ProjectSchema {
  final String projectName;
  final List<SchemaEntity> entities;

  ProjectSchema({required this.projectName, required this.entities});

  factory ProjectSchema.fromJson(Map<String, dynamic> json) {
    final projectName =
        json['proyecto']?.toString() ??
        json['projectName']?.toString() ??
        'Proyecto Genérico';
    final rawEntities = json['entidades'] ?? json['entities'] ?? [];
    final List<SchemaEntity> entitiesList = [];

    if (rawEntities is List) {
      for (final e in rawEntities) {
        if (e is Map<String, dynamic>) {
          entitiesList.add(SchemaEntity.fromJson(e));
        }
      }
    }

    return ProjectSchema(projectName: projectName, entities: entitiesList);
  }

  Map<String, dynamic> toJson() => {
    'proyecto': projectName,
    'entidades': entities.map((e) => e.toJson()).toList(),
  };

  bool supportsAction(String action) {
    final normalized = action.trim().toUpperCase();
    final separator = normalized.indexOf('_');
    if (separator <= 0 || separator == normalized.length - 1) return false;

    final operation = normalized.substring(0, separator);
    final entityName = normalized.substring(separator + 1);

    for (final entity in entities) {
      final normalizedEntity = entity.name
          .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
          .toUpperCase();
      if (normalizedEntity == entityName && entity.supports(operation)) {
        return true;
      }
    }
    return false;
  }

  /// Genera un contrato NLU compacto y dinamico para cualquier backend.
  String toNluActionCatalog() {
    final buffer = StringBuffer();

    for (final entity in entities) {
      final cleanName = entity.name.replaceAll(' ', '_').toUpperCase();

      final fieldsSpec = entity.fields
          .map((f) => '"${f.name}": ${f.type}')
          .join(', ');
      if (entity.supports('CREAR')) {
        buffer.writeln('- CREAR_$cleanName: {$fieldsSpec}');
      }
      if (entity.supports('LISTAR')) {
        buffer.writeln('- LISTAR_$cleanName: {}');
      }
      if (entity.supports('OBTENER')) {
        buffer.writeln('- OBTENER_$cleanName: {"id": int}');
      }
      if (entity.supports('ELIMINAR')) {
        buffer.writeln('- ELIMINAR_$cleanName: {"id": int}');
      }
      if (entity.supports('ACTUALIZAR')) {
        buffer.writeln('- ACTUALIZAR_$cleanName: {"id": int, $fieldsSpec}');
      }
    }

    return buffer.toString().trim();
  }
}
