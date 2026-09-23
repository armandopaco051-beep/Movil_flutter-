import 'dart:io';

import 'package:flutter/services.dart';

class DiscoveredBackend {
  final String serviceName;
  final String project;
  final String host;
  final int port;
  final String schemaVersion;

  const DiscoveredBackend({
    required this.serviceName,
    required this.project,
    required this.host,
    required this.port,
    required this.schemaVersion,
  });

  String get baseUrl {
    final formattedHost = host.contains(':') ? '[$host]' : host;
    return 'http://$formattedHost:$port';
  }

  factory DiscoveredBackend.fromMap(Map<Object?, Object?> map) {
    return DiscoveredBackend(
      serviceName: map['serviceName']?.toString() ?? 'DrawSchema Backend',
      project: map['project']?.toString() ?? 'Proyecto sin nombre',
      host: map['host']?.toString() ?? '',
      port: int.tryParse(map['port']?.toString() ?? '') ?? 0,
      schemaVersion: map['schemaVersion']?.toString() ?? '',
    );
  }
}

class BackendDiscoveryService {
  static const MethodChannel _channel = MethodChannel(
    'drawschema.ai/backend_discovery',
  );

  Future<List<DiscoveredBackend>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (!Platform.isAndroid) return const [];

    final rawServices = await _channel.invokeListMethod<Object?>(
      'discoverBackends',
      {'timeoutMs': timeout.inMilliseconds},
    );

    final unique = <String, DiscoveredBackend>{};
    for (final raw in rawServices ?? const <Object?>[]) {
      if (raw is! Map) continue;
      final backend = DiscoveredBackend.fromMap(raw);
      if (backend.host.isEmpty || backend.port <= 0) continue;
      unique[backend.baseUrl] = backend;
    }

    return unique.values.toList()..sort(
      (a, b) => a.project.toLowerCase().compareTo(b.project.toLowerCase()),
    );
  }
}
