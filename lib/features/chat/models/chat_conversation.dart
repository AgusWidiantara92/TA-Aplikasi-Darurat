import 'package:flutter/material.dart';

/// Model item percakapan di halaman daftar pesan.
class ChatConversation {
  final String id;
  final String title;
  final String nodeId;
  final String? peerNodeId;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final String badgeText;
  final Color badgeBgColor;
  final Color badgeTextColor;
  final String? statusLabel;
  final bool isEmergency;
  final bool isConnectedNode;

  const ChatConversation({
    required this.id,
    required this.title,
    required this.nodeId,
    this.peerNodeId,
    required this.lastMessage,
    required this.time,
    this.unreadCount = 0,
    required this.badgeText,
    required this.badgeBgColor,
    required this.badgeTextColor,
    this.statusLabel,
    this.isEmergency = false,
    this.isConnectedNode = true,
  });

  ChatConversation copyWith({
    String? id,
    String? title,
    String? nodeId,
    String? peerNodeId,
    String? lastMessage,
    String? time,
    int? unreadCount,
    String? badgeText,
    Color? badgeBgColor,
    Color? badgeTextColor,
    String? statusLabel,
    bool? isEmergency,
    bool? isConnectedNode,
  }) {
    return ChatConversation(
      id: id ?? this.id,
      title: title ?? this.title,
      nodeId: nodeId ?? this.nodeId,
      peerNodeId: peerNodeId ?? this.peerNodeId,
      lastMessage: lastMessage ?? this.lastMessage,
      time: time ?? this.time,
      unreadCount: unreadCount ?? this.unreadCount,
      badgeText: badgeText ?? this.badgeText,
      badgeBgColor: badgeBgColor ?? this.badgeBgColor,
      badgeTextColor: badgeTextColor ?? this.badgeTextColor,
      statusLabel: statusLabel ?? this.statusLabel,
      isEmergency: isEmergency ?? this.isEmergency,
      isConnectedNode: isConnectedNode ?? this.isConnectedNode,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'nodeId': nodeId,
    'peerNodeId': peerNodeId,
    'lastMessage': lastMessage,
    'time': time,
    'unreadCount': unreadCount,
    'badgeText': badgeText,
    'badgeBgColor': badgeBgColor.toARGB32(),
    'badgeTextColor': badgeTextColor.toARGB32(),
    'statusLabel': statusLabel,
    'isEmergency': isEmergency,
    'isConnectedNode': isConnectedNode,
  };

  factory ChatConversation.fromJson(Map<String, dynamic> json) {
    return ChatConversation(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      nodeId: json['nodeId'] as String? ?? '',
      peerNodeId: json['peerNodeId'] as String?,
      lastMessage: json['lastMessage'] as String? ?? '',
      time: json['time'] as String? ?? '',
      unreadCount: json['unreadCount'] as int? ?? 0,
      badgeText: json['badgeText'] as String? ?? '',
      badgeBgColor: Color(json['badgeBgColor'] as int? ?? 0xFF0A192F),
      badgeTextColor: Color(json['badgeTextColor'] as int? ?? 0xFFFFFFFF),
      statusLabel: json['statusLabel'] as String?,
      isEmergency: json['isEmergency'] as bool? ?? false,
      isConnectedNode: json['isConnectedNode'] as bool? ?? true,
    );
  }
}
