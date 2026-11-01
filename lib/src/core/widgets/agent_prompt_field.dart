import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Shared multiline editor for Agent instructions that are configured rather
/// than sent in realtime.
class AgentPromptField extends StatelessWidget {
  const AgentPromptField({
    required this.controller,
    this.hintText,
    this.enabled = true,
    this.minLines = 3,
    this.maxLines = 6,
    this.maxLength,
    this.focusNode,
    this.autofocus = false,
    this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String? hintText;
  final bool enabled;
  final int minLines;
  final int maxLines;
  final int? maxLength;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AppGlassField(
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      enabled: enabled,
      minLines: minLines,
      maxLines: maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      textCapitalization: TextCapitalization.sentences,
      onChanged: onChanged,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    );
  }
}
