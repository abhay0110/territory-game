import 'package:HexTrail/core/constants/launch_corridor.dart';
import 'package:HexTrail/core/constants/valid_trail_hexes.dart';

void main() {
  LaunchCorridor.ensureInitialized();
  ValidTrailHexes.ensureInitialized();

  final corridorHexes = LaunchCorridor.hexes;
  final corridorOrdered = LaunchCorridor.orderedHexes;
  final validHexes = ValidTrailHexes.validHexIds;

  print('Corridor hexes (set): ${corridorHexes.length}');
  print('Corridor ordered: ${corridorOrdered.length}');
  print('Valid trail hexes: ${validHexes.length}');
  print('Rejected from corridor: ${ValidTrailHexes.debugRejectedCount}');

  final inCorridorNotValid = corridorHexes.difference(validHexes);
  print('\nIn corridor but NOT valid: ${inCorridorNotValid.length}');
  for (final hex in inCorridorNotValid.take(20)) {
    final dist = ValidTrailHexes.debugDistanceForHex(hex);
    print('  $hex  dist=${dist?.toStringAsFixed(1) ?? "N/A"}');
  }

  final inValidNotCorridor = validHexes.difference(corridorHexes);
  print('\nIn valid but NOT corridor: ${inValidNotCorridor.length}');
  for (final hex in inValidNotCorridor.take(10)) {
    print('  $hex');
  }
}
