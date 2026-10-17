import 'package:flutter/material.dart';

/// Model item percakapan di halaman daftar pesan (simulasi).
class ChatConversation {
  final String id;
  final String title;
  final String nodeId;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final String badgeText;
  final Color badgeBgColor;
  final Color badgeTextColor;
  final String? statusLabel;
  final bool isEmergency;

  const ChatConversation({
    required this.id,
    required this.title,
    required this.nodeId,
    required this.lastMessage,
    required this.time,
    this.unreadCount = 0,
    required this.badgeText,
    required this.badgeBgColor,
    required this.badgeTextColor,
    this.statusLabel,
    this.isEmergency = false,
  });
}
