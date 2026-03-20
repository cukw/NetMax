// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'package:http/http.dart' as http;

http.Client createNetMaxHttpClient({required bool allowBadCertificates}) {
  return http.Client();
}
