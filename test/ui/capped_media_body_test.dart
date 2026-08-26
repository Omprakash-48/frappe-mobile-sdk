// `FormScreen._fetchMediaBytes` bounded the connect/headers phase but not the
// body: once the response object existed the `send` timeout was satisfied, so a
// connection that went quiet mid-download left the resolve future permanently
// unresolved and the field stuck. `AttachField`'s downloader already guarded
// this (`_AttachViewButtonState.stallTimeout`); this path did not. Round-4
// review M5.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/form_screen.dart';
import 'package:http/http.dart' as http;

void main() {
  const cap = 1000;

  http.StreamedResponse responseOf(
    Stream<List<int>> body, {
    int? contentLength,
  }) => http.StreamedResponse(body, 200, contentLength: contentLength);

  test('a complete body is returned', () async {
    final bytes = await readCappedMediaBody(
      responseOf(
        Stream.fromIterable([
          <int>[1, 2],
          <int>[3],
        ]),
      ),
      cap: cap,
    );
    expect(bytes, <int>[1, 2, 3]);
  });

  test('a declared oversize is refused before any chunk is read', () async {
    var read = false;
    final body =
        Stream<List<int>>.fromIterable([
          <int>[1],
        ]).map((c) {
          read = true;
          return c;
        });

    final bytes = await readCappedMediaBody(
      responseOf(body, contentLength: cap + 1),
      cap: cap,
    );

    expect(bytes, isNull);
    expect(read, isFalse, reason: 'Content-Length must short-circuit');
  });

  test('an undeclared oversize is caught mid-stream', () async {
    final bytes = await readCappedMediaBody(
      responseOf(Stream.fromIterable([List.filled(cap + 1, 0)])),
      cap: cap,
    );
    expect(bytes, isNull);
  });

  test('a stream that goes quiet mid-body gives up instead of hanging', () async {
    // Emits one chunk then never completes — the shape of a dropped connection.
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    controller.add(<int>[1, 2, 3]);

    final result =
        await readCappedMediaBody(
          responseOf(controller.stream),
          cap: cap,
          stallTimeout: const Duration(milliseconds: 50),
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('hung — the stall bound did not fire'),
        );

    expect(
      result,
      isNull,
      reason: 'a stall is a failed fetch, not a partial one',
    );
  });

  test('a stream that never emits at all also gives up', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);

    final result =
        await readCappedMediaBody(
          responseOf(controller.stream),
          cap: cap,
          stallTimeout: const Duration(milliseconds: 50),
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('hung — the stall bound did not fire'),
        );

    expect(result, isNull);
  });
}
