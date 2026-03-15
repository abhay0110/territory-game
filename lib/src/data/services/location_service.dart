import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;

/// Handles location permission checks and provides position streams.
///
/// Keeps UI logic out of the widget by returning results and errors, while
/// leaving SnackBar/alert display to the caller.
class LocationService {
  /// Returns true if the user has granted location permission and services are enabled.
  Future<bool> ensurePermission({required BuildContext context}) async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Turn on Location Services on your phone.')),
        );
      }
      return false;
    }

    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }

    if (perm == geo.LocationPermission.denied ||
        perm == geo.LocationPermission.deniedForever) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission denied.')),
        );
      }
      return false;
    }

    return true;
  }

  Future<geo.Position> getCurrentPosition() {
    return geo.Geolocator.getCurrentPosition(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
      ),
    );
  }

  Stream<geo.Position> getPositionStream({geo.LocationSettings? settings}) {
    return geo.Geolocator.getPositionStream(
      locationSettings: settings ??
          const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 15,
          ),
    );
  }
}
