import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/app_guard.dart';

void main() {
  group('SemVer parsing', () {
    test('parses simple version strings', () {
      final v = SemVer.parse('1.2.3');
      expect(v.major, equals(1));
      expect(v.minor, equals(2));
      expect(v.patch, equals(3));
    });

    test('parses versions prefixed with v/V', () {
      final v1 = SemVer.parse('v2.0.1');
      final v2 = SemVer.parse('V3.4.5');
      expect(v1.major, equals(2));
      expect(v1.minor, equals(0));
      expect(v1.patch, equals(1));
      expect(v2.major, equals(3));
      expect(v2.minor, equals(4));
      expect(v2.patch, equals(5));
    });

    test('ignores prerelease and build metadata', () {
      final v1 = SemVer.parse('1.0.0-beta.1');
      final v2 = SemVer.parse('1.0.0+build.123');
      final v3 = SemVer.parse('1.0.0-alpha+001');
      expect(v1.major, equals(1));
      expect(v1.minor, equals(0));
      expect(v1.patch, equals(0));
      expect(v2.major, equals(1));
      expect(v2.minor, equals(0));
      expect(v2.patch, equals(0));
      expect(v3.major, equals(1));
      expect(v3.minor, equals(0));
      expect(v3.patch, equals(0));
    });

    test('handles invalid strings gracefully', () {
      final v1 = SemVer.parse('abc');
      final v2 = SemVer.parse('');
      expect(v1.major, equals(0));
      expect(v1.minor, equals(0));
      expect(v1.patch, equals(0));
      expect(v2.major, equals(0));
      expect(v2.minor, equals(0));
      expect(v2.patch, equals(0));
    });
  });

  group('SemVer comparison', () {
    test('isLessThan checks correctly', () {
      // major difference
      expect(SemVer.parse('1.0.0').isLessThan(SemVer.parse('2.0.0')), isTrue);
      expect(SemVer.parse('2.0.0').isLessThan(SemVer.parse('1.0.0')), isFalse);

      // minor difference
      expect(SemVer.parse('1.0.0').isLessThan(SemVer.parse('1.1.0')), isTrue);
      expect(SemVer.parse('1.1.0').isLessThan(SemVer.parse('1.0.0')), isFalse);

      // patch difference
      expect(SemVer.parse('1.0.0').isLessThan(SemVer.parse('1.0.1')), isTrue);
      expect(SemVer.parse('1.0.1').isLessThan(SemVer.parse('1.0.0')), isFalse);

      // equal versions
      expect(SemVer.parse('1.0.0').isLessThan(SemVer.parse('1.0.0')), isFalse);
    });

    test('isMajorLessThan checks correctly', () {
      expect(
        SemVer.parse('1.0.0').isMajorLessThan(SemVer.parse('2.0.0')),
        isTrue,
      );
      expect(
        SemVer.parse('1.5.0').isMajorLessThan(SemVer.parse('2.0.0')),
        isTrue,
      );
      expect(
        SemVer.parse('2.0.0').isMajorLessThan(SemVer.parse('2.0.0')),
        isFalse,
      );
      expect(
        SemVer.parse('2.1.0').isMajorLessThan(SemVer.parse('2.0.0')),
        isFalse,
      );
    });
  });
}
