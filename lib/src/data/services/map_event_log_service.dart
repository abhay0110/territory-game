import 'package:flutter/foundation.dart';

enum MapEventType {
  tileCaptured,
  protectionRefreshed,
  blockedByRivalProtection,
  rivalTakeover,
  sessionStarted,
  sessionStopped,
  milestoneUnlocked,
}

class MapEvent {
  final MapEventType type;
  final String message;
  final DateTime timestamp;
  final Map<String, Object?> metadata;

  const MapEvent({
    required this.type,
    required this.message,
    required this.timestamp,
    this.metadata = const {},
  });
}

class MapEventLogService {
  final List<MapEvent> _events = [];

  List<MapEvent> get events => List.unmodifiable(_events);

  void log(
    MapEventType type,
    String message, {
    Map<String, Object?> metadata = const {},
  }) {
    final event = MapEvent(
      type: type,
      message: message,
      timestamp: DateTime.now(),
      metadata: metadata,
    );

    _events.add(event);
    if (_events.length > 300) {
      _events.removeAt(0);
    }

    debugPrint('[MapEvent][${event.type.name}] ${event.message} ${event.metadata}');
  }
}
