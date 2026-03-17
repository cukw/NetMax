import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';
import 'package:web_socket_channel/io.dart';

import 'proxy_transport_service_base.dart';

ProxyTransportServiceBase createProxyTransportService() {
  return _IoProxyTransportService();
}

class _IoProxyTransportService implements ProxyTransportServiceBase {
  @override
  bool get supportsCustomProxy => true;

  @override
  Future<Duration?> probeHealth({
    required Uri healthUri,
    required Duration timeout,
    ProxyEndpoint? proxy,
  }) async {
    final client = await _buildClient(proxy);
    try {
      final started = DateTime.now();
      final request = await client.getUrl(healthUri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<List<int>>();
      if (response.statusCode != 200) {
        return null;
      }
      return DateTime.now().difference(started);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<ProxyWebSocketSession> openWebSocket({
    required Uri uri,
    ProxyEndpoint? proxy,
  }) async {
    if (proxy == null) {
      return ProxyWebSocketSession(
        channel: IOWebSocketChannel.connect(uri),
        dispose: () async {},
      );
    }

    final client = await _buildClient(proxy);
    final channel = IOWebSocketChannel.connect(uri, customClient: client);
    return ProxyWebSocketSession(
      channel: channel,
      dispose: () async {
        client.close(force: true);
      },
    );
  }

  Future<HttpClient> _buildClient(ProxyEndpoint? proxy) async {
    final client = HttpClient();
    if (proxy == null) {
      return client;
    }

    if (proxy.isHttpProxy) {
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}; DIRECT';
      final hasCredentials =
          proxy.username != null &&
          proxy.username!.isNotEmpty &&
          proxy.password != null;
      if (hasCredentials) {
        client.authenticateProxy = (host, port, scheme, realm) async {
          if (host != proxy.host || port != proxy.port) {
            return false;
          }
          client.addProxyCredentials(
            host,
            port,
            realm ?? '',
            HttpClientBasicCredentials(proxy.username!, proxy.password!),
          );
          return true;
        };
      }
      return client;
    }

    if (proxy.isSocksProxy) {
      final resolved = await _resolveHost(proxy.host);
      if (resolved == null) {
        return client;
      }

      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(
          resolved,
          proxy.port,
          username: proxy.username,
          password: proxy.password,
        ),
      ]);
      return client;
    }

    return client;
  }

  Future<InternetAddress?> _resolveHost(String host) async {
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      return parsed;
    }

    try {
      final resolved = await InternetAddress.lookup(host);
      if (resolved.isEmpty) {
        return null;
      }
      return resolved.first;
    } catch (_) {
      return null;
    }
  }
}
