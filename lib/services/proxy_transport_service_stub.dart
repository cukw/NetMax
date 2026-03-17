import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'proxy_transport_service_base.dart';

ProxyTransportServiceBase createProxyTransportService() {
  return _StubProxyTransportService();
}

class _StubProxyTransportService implements ProxyTransportServiceBase {
  @override
  bool get supportsCustomProxy => false;

  @override
  Future<Duration?> probeHealth({
    required Uri healthUri,
    required Duration timeout,
    ProxyEndpoint? proxy,
  }) async {
    if (proxy != null) {
      return null;
    }
    try {
      final started = DateTime.now();
      final response = await http.get(healthUri).timeout(timeout);
      if (response.statusCode != 200) {
        return null;
      }
      return DateTime.now().difference(started);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ProxyWebSocketSession> openWebSocket({
    required Uri uri,
    ProxyEndpoint? proxy,
  }) async {
    final channel = WebSocketChannel.connect(uri);
    return ProxyWebSocketSession(channel: channel, dispose: () async {});
  }
}
