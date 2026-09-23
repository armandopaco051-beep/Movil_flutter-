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
      return EntityField(name: name, type: value);
    } else if (value is Map<String, dynamic>) {
      return EntityField(
        name: name,
        type: value['type']?.toString() ?? 'string',
        isRequired: value['required'] == true,
      );
    }
    return EntityField(name: name, type: 'string');
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'required': isRequired,
  };
}

class SchemaEntity {
  final String name; // e.g. "Herramienta", "Jugador", "Producto"
  final String endpoint; // e.g. "/api/herramientas", "/api/jugadores"
  final List<EntityField> fields;

  SchemaEntity({
    required this.name,
    required this.endpoint,
    required this.fields,
  });

  factory SchemaEntity.fromJson(Map<String, dynamic> json) {
    final name = json['nombre']?.toString() ?? json['name']?.toString() ?? 'Entidad';
    final endpoint = json['endpoint']?.toString() ?? '/api/${_defaultPluralize(name.toLowerCase())}';

    final rawFields = json['atributos'] ?? json['campos'] ?? json['fields'] ?? {};
    final List<EntityField> fieldsList = [];

    if (rawFields is Map) {
      rawFields.forEach((key, val) {
        fieldsList.add(EntityField.fromJson(key.toString(), val));
      });
    } else if (rawFields is List) {
      for (final f in rawFields) {
        if (f is Map<String, dynamic>) {
          fieldsList.add(EntityField(
            name: f['nombre'] ?? f['name'] ?? 'campo',
            type: f['tipo'] ?? f['type'] ?? 'string',
            isRequired: f['requerido'] ?? f['required'] ?? false,
          ));
        }
      }
    }

    return SchemaEntity(
      name: name,
      endpoint: endpoint,
      fields: fieldsList,
    );
  }

  Map<String, dynamic> toJson() => {
    'nombre': name,
    'endpoint': endpoint,
    'atributos': {for (var f in fields) f.name: f.toJson()},
  };

  static String _defaultPluralize(String word) {
    if (word.endsWith('s')) return word;
    if (word.endsWith('r') || word.endsWith('l') || word.endsWith('n')) return '${word}es';
    return '${word}s';
  }
}

class ProjectSchema {
  final String projectName;
  final List<SchemaEntity> entities;

  ProjectSchema({
    required this.projectName,
    required this.entities,
  });

  factory ProjectSchema.fromJson(Map<String, dynamic> json) {
    final projectName = json['proyecto']?.toString() ?? json['projectName']?.toString() ?? 'Proyecto Genérico';
    final rawEntities = json['entidades'] ?? json['entities'] ?? [];
    final List<SchemaEntity> entitiesList = [];

    if (rawEntities is List) {
      for (final e in rawEntities) {
        if (e is Map<String, dynamic>) {
          entitiesList.add(SchemaEntity.fromJson(e));
        }
      }
    }

    return ProjectSchema(
      projectName: projectName,
      entities: entitiesList,
    );
  }

  Map<String, dynamic> toJson() => {
    'proyecto': projectName,
    'entidades': entities.map((e) => e.toJson()).toList(),
  };

  /// Genera el catálogo de acciones en formato texto para inyectar en el Prompt de Qwen 2.5 0.5B
  String toNluActionCatalog() {
    final buffer = StringBuffer();

    for (final entity in entities) {
      final cleanName = entity.name.replaceAll(' ', '_').toUpperCase();

      // CREAR
      final fieldsSpec = entity.fields.map((f) => '"${f.name}": ${f.type}').join(', ');
      buffer.writeln('- CREAR_$cleanName: {$fieldsSpec}');

      // LISTAR
      buffer.writeln('- LISTAR_$cleanName: {}');

      // ELIMINAR
      buffer.writeln('- ELIMINAR_$cleanName: {"id": int}');

      // ACTUALIZAR
      buffer.writeln('- ACTUALIZAR_$cleanName: {"id": int, $fieldsSpec}');
    }

    return buffer.toString().trim();
  }
}
