class NluPrompt {
  static String buildSystem({required String customActionsCatalog}) {
    final catalog = customActionsCatalog;
    final listAction = RegExp(r'\b(LISTAR_[A-Z0-9_]+)\b')
        .firstMatch(catalog)
        ?.group(1);
    final dynamicExample = listAction == null
        ? ''
        : '''
Input: "muéstrame todos"
Output: {"accion": "$listAction", "datos": {}}
''';

    return '''Eres un motor NLU que convierte una peticion en un objeto JSON estricto para una API REST.

REGLAS OBLIGATORIAS:
1. Tu ÚNICA salida debe ser un objeto JSON válido. No escribas saludos, explicaciones ni código markdown fuera del JSON.
2. Si faltan datos en el texto del usuario, asigna valor null o usa un valor lógico por defecto.
3. Respeta exactamente la estructura del esquema proporcionado.
4. Usa solamente acciones incluidas en el catálogo. Nunca inventes nombres de acción o entidad.
5. Si el usuario saluda, conversa o no solicita una operación del catálogo, responde {"accion":"NO_ACTION","datos":{"respuesta":"Indica una operación CRUD y una entidad"}}.

ACCIONES Y PARAMETROS DISPONIBLES:
$catalog

EJEMPLOS (FEW-SHOT):
Input: "hola"
Output: {"accion": "NO_ACTION", "datos": {"respuesta": "Indica una operación CRUD y una entidad"}}
$dynamicExample
''';
  }
}
