import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';

void main() {
  test('snapshot rows are excluded from link-option pickers', () {
    final svc = LinkOptionService.withoutResolver();
    final out = svc.rowsToEntitiesForTest(
      [
        {
          'server_name': 'CUST-1',
          'customer_name': 'Synced',
          'sync_status': 'synced',
        },
        {
          'mobile_uuid': 'u-2',
          'customer_name': 'Half typed',
          'sync_status': 'snapshot',
        },
      ],
      'Customer',
      'customer_name',
    );

    expect(out.length, 1, reason: 'the snapshot row must not be offered');
    expect(out.single.label, 'Synced');
  });
}
