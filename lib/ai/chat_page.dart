import 'package:flutter/material.dart';

import 'assistant.dart';
import 'assistant_panel.dart';

/// The Ask page: the same conversation as the side panel, full size.
class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.controller, required this.onOpenSettings});

  final AssistantController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => AssistantChat(controller: controller, onOpenSettings: onOpenSettings);
}
