import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_details.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

DoctypeService _svc(http.Client client) =>
    DoctypeService(RestHelper('http://x', client: client));

void main() {
  test('returns null for empty input without a network call', () async {
    var hit = false;
    final svc = _svc(
      MockClient((_) async {
        hit = true;
        return _json({'message': {}});
      }),
    );
    final r = await svc.getSyncDetails(const []);
    expect(r, isNull);
    expect(hit, isFalse, reason: 'empty input must not call the network');
  });

  test('posts the right body and parses a message-wrapped manifest', () async {
    String? capturedPath;
    Map<String, dynamic>? capturedBody;
    final svc = _svc(
      MockClient((req) async {
        capturedPath = req.url.path;
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'message': {
            'doctypes': [
              {
                'doctype': 'Patient',
                'changed': true,
                'count': 2,
                'meta_bumped': false,
              },
            ],
            'delete_signals': 0,
          },
        });
      }),
    );
    final r = await svc.getSyncDetails([
      {'doctype': 'Patient', 'since': '2026-01-01 00:00:00.000000'},
    ]);
    expect(capturedPath, '/api/method/mobile_sync.sync_details');
    expect((capturedBody!['doctypes'] as List).first['doctype'], 'Patient');
    expect(r, isA<SyncDetailsResponse>());
    expect(r!.entries['Patient']!.changed, isTrue);
    expect(r.entries['Patient']!.count, 2);
  });

  test('returns null on transport error (graceful fallback)', () async {
    final svc = _svc(MockClient((_) async => _json({'error': 'boom'}, 500)));
    final r = await svc.getSyncDetails([
      {'doctype': 'Patient', 'since': '2026-01-01 00:00:00.000000'},
    ]);
    expect(r, isNull);
  });
}
