// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'package:http/http.dart' as http;

import 'http_client_factory_stub.dart'
    if (dart.library.io) 'http_client_factory_io.dart'
    as impl;

http.Client createNetMaxHttpClient({required bool allowBadCertificates}) {
  return impl.createNetMaxHttpClient(
    allowBadCertificates: allowBadCertificates,
  );
}
