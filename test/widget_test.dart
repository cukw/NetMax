// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:netmax_messenger/main.dart';

void main() {
  testWidgets('Messenger screen renders', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const NetMaxMessengerApp());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('NetMax Messenger'), findsOneWidget);
    expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });
}
