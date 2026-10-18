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

  Map<String, dynamic> toJson() => {
    'locationName': locationName,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'priority': priority,
    'validationInfo': validationInfo,
  };

  factory TelemetryData.fromJson(Map<String, dynamic> json) {
    return TelemetryData(
      locationName: json['locationName'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      accuracy: json['accuracy'] as String? ?? '',
      priority: json['priority'] as String? ?? '',
      validationInfo: json['validationInfo'] as String? ?? '',
    );
  }
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderName': senderName,
    'text': text,
    'time': time,
    'isMe': isMe,
    'isEmergency': isEmergency,
    'relayInfo': relayInfo,
    'statusText': statusText,
    'telemetryData': telemetryData?.toJson(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      senderName: json['senderName'] as String? ?? '',
      text: json['text'] as String? ?? '',
      time: json['time'] as String? ?? '',
      isMe: json['isMe'] as bool? ?? false,
      isEmergency: json['isEmergency'] as bool? ?? false,
      relayInfo: json['relayInfo'] as String?,
      statusText: json['statusText'] as String?,
      telemetryData: json['telemetryData'] != null
          ? TelemetryData.fromJson(
              json['telemetryData'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}
