// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'proxy_transport_service_base.dart';
import 'proxy_transport_service_stub.dart'
    if (dart.library.io) 'proxy_transport_service_io.dart'
    as impl;

class ProxyTransportService {
  ProxyTransportService._();

  static final ProxyTransportServiceBase instance = impl
      .createProxyTransportService();
}
