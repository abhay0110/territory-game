// Source-level wiring tests for CaptureService.
//
// These complement the pure-logic tests in capture_reconcile_test.dart
// by asserting that the production wiring actually invokes reconcile
// from BOTH refresh paths.  This is the regression net for the
// build-13 wiring bug — a pure unit test cannot catch a missing call
// site.
//
// SHIPPED (Phase 1.X, May 14 2026): wiring landed in capture_service.dart.
// _reconcileLocalCapturesAgainst is invoked from BOTH refreshNearbyOwners
// and refreshCorridorOwners.  cacheReconciliationEnabled is no longer a
// placebo.  These tests are the regression net against re-introducing
// the build-13 wiring bug.
//
// Source-level reasoning is used because CaptureService is heavily
// coupled to Supabase + shared_preferences; bringing in mocktail just
// for these two assertions would be heavier than the value gained.
// If the file is reorganized, update the function-boundary heuristic
// but verify reconcile is still invoked from both refresh methods.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('REGRESSION: capture_service reconcile wiring', () {
    late String source;

    setUpAll(() {
      final file = File('lib/src/data/services/capture_service.dart');
      expect(file.existsSync(), isTrue);
      source = file.readAsStringSync();
    });

    /// Returns the body text of [methodSignature] up to (but not
    /// including) the next top-level `Future<` or `void` method
    /// declaration at the same indent level.
    ///
    /// Matches "Future<...> name(..." method declarations.  The body
    /// is everything between the opening brace and the next
    /// "  Future<" or "  void " at 2-space indent (class methods).
    String _methodBody(String methodSignature) {
      final start = source.indexOf(methodSignature);
      expect(start, greaterThanOrEqualTo(0),
          reason: 'expected to find "$methodSignature" in capture_service.dart');
      // Find next top-level method declaration after this one.
      final searchFrom = start + methodSignature.length;
      final boundaries = <int>[
        source.indexOf(RegExp(r'\n  Future<'), searchFrom),
        source.indexOf(RegExp(r'\n  void '), searchFrom),
        source.indexOf(RegExp(r'\n  static '), searchFrom),
        source.indexOf(RegExp(r'\n  String'), searchFrom),
        source.indexOf(RegExp(r'\n  bool '), searchFrom),
        source.indexOf(RegExp(r'\n}\n'), searchFrom), // class end
      ].where((i) => i > 0).toList()..sort();
      final end = boundaries.isEmpty ? source.length : boundaries.first;
      return source.substring(start, end);
    }

    test('refreshNearbyOwners invokes _reconcileLocalCapturesAgainst', () {
      final body = _methodBody('Future<void> refreshNearbyOwners(');
      expect(
        body.contains('_reconcileLocalCapturesAgainst('),
        isTrue,
        reason:
            'refreshNearbyOwners must call _reconcileLocalCapturesAgainst '
            'so server-truth prunes the local capturedHexes set after each '
            'nearby-ring refresh.  Without this, a tile lost while the '
            'user is near it stays green locally indefinitely.',
      );
    });

    test('refreshCorridorOwners invokes _reconcileLocalCapturesAgainst', () {
      final body = _methodBody('Future<void> refreshCorridorOwners(');
      expect(
        body.contains('_reconcileLocalCapturesAgainst('),
        isTrue,
        reason:
            'refreshCorridorOwners MUST call _reconcileLocalCapturesAgainst '
            'so a user 3+ miles from the corridor still sees lost trail '
            'hexes prune from local cache.  This is the build-13 → build-14 '
            'corridor-gap fix.  Removing this call regresses that bug.',
      );
    });

    test('refreshNearbyOwners passes source: nearby', () {
      final body = _methodBody('Future<void> refreshNearbyOwners(');
      expect(body.contains("source: 'nearby'"), isTrue,
          reason: 'Source tag is used in debug logs to distinguish '
              'nearby vs corridor prunes during field debugging.');
    });

    test('refreshCorridorOwners passes source: corridor', () {
      final body = _methodBody('Future<void> refreshCorridorOwners(');
      expect(body.contains("source: 'corridor'"), isTrue);
    });
  });
}
