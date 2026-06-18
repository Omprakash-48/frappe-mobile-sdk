import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';

void main() {
  test('FrappeException carries mutable wire-capture context', () {
    final e = ValidationException('bad', {'exc_type': 'ValidationError'})
      ..requestUrl = 'https://x.test/api/resource/Foo'
      ..requestMethod = 'POST'
      ..requestBody = {'a': 1}
      ..responseBodyRaw = '{"exc_type":"ValidationError"}'
      ..traceId = 'abc123';

    expect(e.requestUrl, 'https://x.test/api/resource/Foo');
    expect(e.requestMethod, 'POST');
    expect(e.requestBody, {'a': 1});
    expect(e.responseBodyRaw, contains('ValidationError'));
    expect(e.traceId, 'abc123');
    expect(e.statusCode, 417); // ValidationException default
  });

  test('AuthException inherits the same fields', () {
    final e = AuthException('nope', 403)..responseBodyRaw = '{"exc":"x"}';
    expect(e.responseBodyRaw, '{"exc":"x"}');
    expect(e.requestUrl, isNull);
  });
}
