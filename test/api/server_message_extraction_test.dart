import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart'
    show extractErrorMessage, toUserFriendlyMessage;

void main() {
  const msg =
      'Account number must contain only digits and be between 9 and 18 characters long.';
  // A single Frappe server message object, as embedded (once-encoded) in the
  // `_server_messages` array.
  final innerJson = jsonEncode({
    'message': msg,
    'title': 'Message',
    'indicator': 'red',
    'raise_exception': 1,
  });

  group('_server_messages extraction (via extractErrorMessage)', () {
    test('container is a JSON string of a list of JSON strings', () {
      // Standard Frappe wire shape after one json.decode of the HTTP body.
      final body = {
        'exc_type': 'ValidationError',
        '_server_messages': jsonEncode([innerJson]),
      };
      expect(extractErrorMessage(body), msg);
    });

    test('container is an already-decoded list of JSON strings', () {
      // The shape observed on-device that previously fell through to
      // "Unknown Error".
      final body = {
        'exc_type': 'ValidationError',
        '_server_messages': [innerJson],
      };
      expect(extractErrorMessage(body), msg);
    });

    test('container is a list of maps', () {
      final body = {
        'exc_type': 'ValidationError',
        '_server_messages': [
          {'message': msg, 'title': 'Message'},
        ],
      };
      expect(extractErrorMessage(body), msg);
    });

    test('regression: never returns bare "Unknown Error" for these shapes', () {
      final body = {
        'exc_type': 'ValidationError',
        '_server_messages': [innerJson],
      };
      expect(extractErrorMessage(body), isNot('Unknown Error'));
    });
  });

  group('toUserFriendlyMessage on the same payload', () {
    test('returns the clean sentence for a decoded-list body', () {
      final body = {
        'exc_type': 'ValidationError',
        '_server_messages': [innerJson],
      };
      expect(toUserFriendlyMessage(body), msg);
    });
  });
}
