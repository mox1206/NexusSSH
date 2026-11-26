import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nexus_ssh/src/desktop/desktop_tray_service.dart';
import 'package:nexus_ssh/src/rust/ssh_bridge.dart';
import 'package:nexus_ssh/src/security/biometric_auth_service.dart';
import 'package:nexus_ssh/src/state/app_controller.dart';
import 'package:nexus_ssh/src/ui/app_theme.dart';
import 'package:nexus_ssh/src/ui/workspace_screen.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final backend = RustSshBackend();
  final desktopAdapter = isDesktopHostPlatform
      ? NativeDesktopWindowAdapter()
      : const NoopDesktopWindowAdapter();
  final controller = AppController(
    backend: backend,
    desktopAdapter: desktopAdapter,
    biometricService: LocalBiometricAuthService(),
  );

  final supportDir = await _resolveAppDataDir();
  await controller.initialize(supportDir);

  runApp(NexusSshApp(controller: controller));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    controller.initDesktopTray();
    controller.scheduleStartupUpdateCheck();
  });
}

Future<String> _resolveAppDataDir() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  } catch (_) {
    final fallback = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}nexus_ssh',
    );
    if (!fallback.existsSync()) {
      fallback.createSync(recursive: true);
    }
    return fallback.path;
  }
}

class NexusSshApp extends StatelessWidget {
  const NexusSshApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus SSH',
      debugShowCheckedModeBanner: false,
      theme: NexusTheme.dark(),
      home: WorkspaceScreen(controller: controller),
    );
  }
}
