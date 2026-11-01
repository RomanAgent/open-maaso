import 'package:flutter/material.dart';

/// Transparent media navigation. Only floating actions use a frost surface;
/// tabs remain directly over the image, with an underline for selection.
class ImmersiveFeedTab extends StatelessWidget {
  const ImmersiveFeedTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: Colors.transparent,
          foregroundColor: selected
              ? Colors.white
              : Colors.white.withValues(alpha: .87),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 15,
            height: 20 / 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Container(
              width: 16,
              height: 2,
              color: selected ? Colors.white : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}
