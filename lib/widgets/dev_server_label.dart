import 'package:flutter/material.dart';

import '../dev_config.dart';

/// Small "DEV · local server" note in emulator builds
/// ([DevConfig.useEmulator]), so such a build is never mistaken for the real
/// one. Renders nothing otherwise.
class DevServerLabel extends StatelessWidget {
  /// Text colour; defaults to a muted on-surface colour.
  final Color? color;

  const DevServerLabel({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    if (!DevConfig.useEmulator) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: Text(
          'DEV · local server ${DevConfig.emulatorHost}',
          style: TextStyle(
            fontSize: 12,
            color: color ??
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
