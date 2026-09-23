import 'package:app_movil_ia_local/models/project_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interpreta el contrato generado por Spring Boot', () {
    final schema = ProjectSchema.fromJson({
      'proyecto': 'Restaurante API',
      'entidades': [
        {
          'nombre': 'Productos',
          'endpoint': '/api/productos',
          'atributos': {
            'nombre': {'type': 'string', 'required': true},
            'precio': {'type': 'double', 'required': true},
          },
          'operaciones': [
            'CREAR',
            'LISTAR',
            'OBTENER',
            'ACTUALIZAR',
            'ELIMINAR',
          ],
        },
      ],
    });

    expect(schema.projectName, 'Restaurante API');
    expect(schema.entities.single.endpoint, '/api/productos');
    expect(schema.entities.single.fields.first.name, 'nombre');
    expect(schema.supportsAction('LISTAR_PRODUCTOS'), isTrue);
    expect(schema.supportsAction('CREAR_CLIENTE'), isFalse);
    expect(schema.toNluActionCatalog(), contains('CREAR_PRODUCTOS'));
  });
}
