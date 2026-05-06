// Default Flutter scaffold widget test.
//
// Pumping the real app requires Supabase init, a Mapbox token, and a
// ProviderScope, none of which are available in the unit-test harness.
// Real UI coverage lives in the per-widget tests under test/unit/.
// This file is intentionally kept (rather than deleted) so a future
// hermetic widget smoke test can land here without re-adding scaffolding.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder — see comment above', () {
    expect(true, isTrue);
  }, skip: 'Replace with hermetic widget smoke once test harness is wired.');
}
