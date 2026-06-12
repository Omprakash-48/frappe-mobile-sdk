import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/mobile_error_record.dart';

void main() {
  test('operationName maps HTTP method to Frappe operation', () {
    expect(operationName('POST'), 'INSERT');
    expect(operationName('PUT'), 'UPDATE');
    expect(operationName('SUBMIT'), 'SUBMIT');
    expect(operationName('CANCEL'), 'CANCEL');
    expect(operationName('DELETE'), 'DELETE');
    expect(operationName('weird'), 'WEIRD'); // fallback: uppercased
  });

  test('excTypeFromBody extracts Frappe exc_type, else empty', () {
    expect(
      excTypeFromBody('{"exc_type":"ValidationError"}'),
      'ValidationError',
    );
    expect(excTypeFromBody('not json'), '');
    expect(excTypeFromBody(null), '');
  });
}
