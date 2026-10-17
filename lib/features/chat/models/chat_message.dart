/// Model data telemetri darurat (mock) untuk simulasi attachment chat.
class TelemetryData {
  final String locationName;
  final double latitude;
  final double longitude;
  final String accuracy;
  final String priority;
  final String validationInfo;

  const TelemetryData({
    required this.locationName,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.priority,
    required this.validationInfo,
  });
}

/// Model pesan percakapan (simulasi lokal).
class ChatMessage {
  final String id;
  final String senderName;
  final String text;
  final String time;
  final bool isMe;
  final bool isEmergency;
  final String? relayInfo;
  final String? statusText;
  final TelemetryData? telemetryData;

  const ChatMessage({
    required this.id,
    required this.senderName,
    required this.text,
    required this.time,
    required this.isMe,
    this.isEmergency = false,
    this.relayInfo,
    this.statusText,
    this.telemetryData,
  });

  ChatMessage copyWith({
    String? id,
    String? senderName,
    String? text,
    String? time,
    bool? isMe,
    bool? isEmergency,
    String? relayInfo,
    String? statusText,
    TelemetryData? telemetryData,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderName: senderName ?? this.senderName,
      text: text ?? this.text,
      time: time ?? this.time,
      isMe: isMe ?? this.isMe,
      isEmergency: isEmergency ?? this.isEmergency,
      relayInfo: relayInfo ?? this.relayInfo,
      statusText: statusText ?? this.statusText,
      telemetryData: telemetryData ?? this.telemetryData,
    );
  }
}
