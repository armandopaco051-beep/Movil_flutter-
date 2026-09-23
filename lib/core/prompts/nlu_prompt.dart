class NluPrompt {
  static const String defaultActionsCatalog = '''
- CREAR_USUARIO: {"nombre": string, "email": string, "telefono": string|null}
- RESERVAR_MESA: {"cliente_nombre": string, "numero_mesa": int, "cantidad_personas": int, "hora": string}
- CANCELAR_RESERVA: {"reserva_id": int}
- CREAR_PRODUCTO: {"nombre": string, "precio": double, "stock": int, "categoria": string|null}
- LISTAR_REGISTROS: {"entidad": string}
- ELIMINAR_REGISTRO: {"entidad": string, "id": int}
''';

  static String build({
    required String userInput,
    String? customActionsCatalog,
  }) {
    final catalog = customActionsCatalog ?? defaultActionsCatalog;

    return '''<system>
Eres un motor NLU (Natural Language Understanding) especializado en extraer intenciones y entidades de voz/texto y convertirlas a formato JSON estricto para una API REST.

REGLAS OBLIGATORIAS:
1. Tu ÚNICA salida debe ser un objeto JSON válido. No escribas saludos, explicaciones ni código markdown fuera del JSON.
2. Si faltan datos en el texto del usuario, asigna valor null o usa un valor lógico por defecto.
3. Respeta exactamente la estructura del esquema proporcionado.

ACCIONES Y PARAMETROS DISPONIBLES:
$catalog

EJEMPLOS (FEW-SHOT):
Input: "registra a Juan Perez con correo juan@gmail.com"
Output: {"accion": "CREAR_USUARIO", "datos": {"nombre": "Juan Perez", "email": "juan@gmail.com", "telefono": null}}

Input: "Carlos reservó la mesa 5 para 3 personas hoy a las 8pm"
Output: {"accion": "RESERVAR_MESA", "datos": {"cliente_nombre": "Carlos", "numero_mesa": 5, "cantidad_personas": 3, "hora": "20:00"}}

Input: "cancela la reserva 12"
Output: {"accion": "CANCELAR_RESERVA", "datos": {"reserva_id": 12}}
</system>

<user>
$userInput
</user>

<assistant>
''';
  }
}
