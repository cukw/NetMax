// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createNetMaxHttpClient({required bool allowBadCertificates}) {
  final ioClient = HttpClient();
  if (allowBadCertificates) {
    ioClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  }
  return IOClient(ioClient);
}
