import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_details.dart';

void main() {
  group('SyncDetailsResponse.fromJson', () {
    test('parses the frozen schema', () {
      final r = SyncDetailsResponse.fromJson({
        'doctypes': [
          {
            'doctype': 'Patient',
            'changed': true,
            'count': 14,
            'meta_bumped': false,
          },
          {
            'doctype': 'Village',
            'changed': false,
            'count': 0,
            'meta_bumped': true,
          },
        ],
        'delete_signals': 0,
      });
      expect(r.entries.length, 2);
      expect(r.entries['Patient']!.changed, isTrue);
      expect(r.entries['Patient']!.count, 14);
      expect(r.entries['Village']!.changed, isFalse);
      expect(r.entries['Village']!.metaBumped, isTrue);
      expect(r.deleteSignals, 0);
    });

    test('tolerates missing optional fields', () {
      final r = SyncDetailsResponse.fromJson({
        'doctypes': [
          {'doctype': 'X', 'changed': true},
        ],
      });
      expect(r.entries['X']!.count, 0);
      expect(r.entries['X']!.metaBumped, isFalse);
      expect(r.deleteSignals, 0);
    });
  });

  group('doctypesToSkip', () {
    final resp = SyncDetailsResponse.fromJson({
      'doctypes': [
        {
          'doctype': 'Quiet',
          'changed': false,
          'count': 0,
          'meta_bumped': false,
        },
        {'doctype': 'Busy', 'changed': true, 'count': 3, 'meta_bumped': false},
        {
          'doctype': 'MetaMoved',
          'changed': false,
          'count': 0,
          'meta_bumped': true,
        },
      ],
    });

    test('skips only unchanged AND not-meta-bumped doctypes', () {
      final skip = doctypesToSkip({'Quiet', 'Busy', 'MetaMoved'}, resp);
      expect(skip, {'Quiet'});
    });

    test('never skips a doctype absent from the manifest', () {
      final skip = doctypesToSkip({'Quiet', 'NotInManifest'}, resp);
      expect(skip.contains('NotInManifest'), isFalse);
      expect(skip, {'Quiet'});
    });
  });
}
