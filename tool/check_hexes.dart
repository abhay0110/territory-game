import 'package:HexTrail/core/constants/launch_corridor.dart';
import 'package:HexTrail/core/constants/valid_trail_hexes.dart';

void main() {
  LaunchCorridor.ensureInitialized();
  ValidTrailHexes.ensureInitialized();

  final hexes = ['8928d54f003ffff', '8928d54f017ffff', '8928d54f08fffff'];
  for (final hex in hexes) {
    final onCorridor = LaunchCorridor.isOnCorridor(hex);
    final inDisplay = LaunchCorridor.displayHexes.contains(hex);
    final valid = ValidTrailHexes.isValid(hex);
    print('$hex => corridor=$onCorridor display=$inDisplay valid=$valid');
  }
}
