import 'package:app_movil_ia_local/services/backend_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('construye la URL de un backend descubierto por mDNS', () {
    final backend = DiscoveredBackend.fromMap({
      'serviceName': 'restaurante-api',
      'project': 'Restaurante API',
      'host': '192.168.0.4',
      'port': 8086,
      'schemaVersion': '1.0',
    });

    expect(backend.project, 'Restaurante API');
    expect(backend.baseUrl, 'http://192.168.0.4:8086');
  });

  test('encierra una direccion IPv6 entre corchetes', () {
    const backend = DiscoveredBackend(
      serviceName: 'backend-ipv6',
      project: 'Backend IPv6',
      host: 'fe80::1',
      port: 8086,
      schemaVersion: '1.0',
    );

    expect(backend.baseUrl, 'http://[fe80::1]:8086');
  });
}
