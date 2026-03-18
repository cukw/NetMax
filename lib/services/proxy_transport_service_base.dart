// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'package:web_socket_channel/web_socket_channel.dart';

class ProxyEndpoint {
  const ProxyEndpoint({
    required this.scheme,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final String scheme;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get isHttpProxy => scheme == 'http' || scheme == 'https';
  bool get isSocksProxy => scheme == 'socks5' || scheme == 'socks';

  String get id {
    final auth = (username != null && username!.isNotEmpty) ? '$username@' : '';
    return '$scheme://$auth$host:$port';
  }
}

class ProxyWebSocketSession {
  const ProxyWebSocketSession({required this.channel, required this.dispose});

  final WebSocketChannel channel;
  final Future<void> Function() dispose;
}

abstract class ProxyTransportServiceBase {
  bool get supportsCustomProxy;

  Future<Duration?> probeHealth({
    required Uri healthUri,
    required Duration timeout,
    ProxyEndpoint? proxy,
  });

  Future<ProxyWebSocketSession> openWebSocket({
    required Uri uri,
    ProxyEndpoint? proxy,
  });
}
