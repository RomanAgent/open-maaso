import 'package:flutter/material.dart';

/// Offline render of the same shipped doorway mesh, camera and lighting.
class LoginDoorwayArtwork extends StatelessWidget {
  const LoginDoorwayArtwork({super.key});
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Image.asset(
      'assets/brand/login_doorway.png',
      // Keep the complete mat visible while the window or keyboard changes
      // the poster's aspect ratio. The artwork's white floor meets the form.
      fit: BoxFit.contain,
      alignment: Alignment.bottomCenter,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => const SizedBox.expand(),
    ),
  );
}
