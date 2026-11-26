import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

enum DesktopCloseBehavior {
  ask('ask', '每次询问'),
  minimizeToTray('minimize_to_tray', '退到系统托盘'),
  exit('exit', '直接退出');

  const DesktopCloseBehavior(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static DesktopCloseBehavior fromStorage(String? raw) {
    return switch (raw) {
      'minimize_to_tray' => DesktopCloseBehavior.minimizeToTray,
      'exit' => DesktopCloseBehavior.exit,
      _ => DesktopCloseBehavior.ask,
    };
  }
}

bool get isDesktopHostPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

abstract class DesktopWindowAdapter {
  bool get isSupported;

  void initialize({
    required VoidCallback onCloseRequested,
    required VoidCallback onTrayShow,
    required VoidCallback onTrayExit,
  });

  void showAndFocusWindow();
  void hideToTray();
  void exitApp();
  void dispose();
}

/// No-op adapter for mobile platforms (iOS / Android) and headless tests.
class NoopDesktopWindowAdapter implements DesktopWindowAdapter {
  const NoopDesktopWindowAdapter();

  @override
  bool get isSupported => false;

  @override
  void initialize({
    required VoidCallback onCloseRequested,
    required VoidCallback onTrayShow,
    required VoidCallback onTrayExit,
  }) {}

  @override
  void showAndFocusWindow() {}

  @override
  void hideToTray() {}

  @override
  void exitApp() {}

  @override
  void dispose() {}
}

/// Cross-platform Windows / Linux / macOS window-close & system-tray adapter
/// built on `window_manager` and `tray_manager` (`nativeapi`).
class NativeDesktopWindowAdapter implements DesktopWindowAdapter {
  Window? _window;
  ListenerId? _windowListenerId;
  TrayIcon? _trayIcon;
  ListenerId? _trayListenerId;
  Menu? _trayMenu;
  final List<MenuItem> _menuItems = [];
  Image? _trayImage;
  bool _allowImmediateClose = false;
  bool _exiting = false;
  bool _initialized = false;

  VoidCallback? _onTrayShow;
  VoidCallback? _onTrayExit;

  @override
  bool get isSupported => isDesktopHostPlatform;

  @override
  void initialize({
    required VoidCallback onCloseRequested,
    required VoidCallback onTrayShow,
    required VoidCallback onTrayExit,
  }) {
    if (!isSupported || _initialized) return;
    _initialized = true;
    _onTrayShow = onTrayShow;
    _onTrayExit = onTrayExit;

    try {
      final win = WindowManager.instance.getCurrent();
      _window = win;
      if (win != null) {
        _windowListenerId = win.addListener((event) {
          if (event is WindowCloseRequestedEvent) {
            if (_allowImmediateClose) return;
            event.request.cancel();
            onCloseRequested();
          }
        });
      }
    } catch (e) {
      debugPrint('Nexus SSH window close hook skipped: $e');
    }

    _ensureTrayCreated();
  }

  void _ensureTrayCreated() {
    if (!isSupported || _trayIcon != null) return;
    try {
      if (!TrayManager.instance.isSupported()) return;
      final tray = TrayIcon.create();
      if (tray == null) return;

      final primaryAsset = Platform.isWindows
          ? 'assets/icons/app_icon.ico'
          : 'assets/icons/app_icon.png';
      final icon =
          ImageAsset.fromAsset(primaryAsset) ??
          ImageAsset.fromAsset('assets/icons/app_icon.png');
      if (icon != null) {
        tray.icon = icon;
        _trayImage = icon;
      }
      tray.setTooltip('Nexus SSH');

      final menu = Menu.create();
      if (menu != null) {
        final showItem = MenuItem.createWithLabelAndType(
          '显示主窗口',
          MenuItemType.normal,
        );
        if (showItem != null) {
          showItem.addListener((event) {
            if (event is MenuItemClickedEvent) {
              _onTrayShow?.call();
            }
          });
          menu.addItem(showItem);
          _menuItems.add(showItem);
        }

        menu.addSeparator();

        final exitItem = MenuItem.createWithLabelAndType(
          '退出 Nexus SSH',
          MenuItemType.normal,
        );
        if (exitItem != null) {
          exitItem.addListener((event) {
            if (event is MenuItemClickedEvent) {
              _onTrayExit?.call();
            }
          });
          menu.addItem(exitItem);
          _menuItems.add(exitItem);
        }

        tray.setContextMenu(menu);
        tray.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
        _trayMenu = menu;
      }

      _trayListenerId = tray.addListener((event) {
        if (event is TrayIconClickedEvent ||
            event is TrayIconDoubleClickedEvent) {
          _onTrayShow?.call();
        }
      });

      tray.setVisible(true);
      _trayIcon = tray;
    } catch (e) {
      debugPrint('Nexus SSH tray setup skipped: $e');
    }
  }

  @override
  void showAndFocusWindow() {
    final win = _window ?? _tryResolveWindow();
    if (win == null) return;
    try {
      if (win.isMinimized) {
        win.restore();
      }
      win.show();
      win.focus();
    } catch (_) {}
  }

  @override
  void hideToTray() {
    _ensureTrayCreated();
    final win = _window ?? _tryResolveWindow();
    if (win == null) return;
    try {
      win.hide();
    } catch (_) {}
  }

  @override
  void exitApp() {
    if (_exiting) return;
    _exiting = true;
    _allowImmediateClose = true;

    final win = _window ?? _tryResolveWindow();
    // Hide window & tray icon immediately so exit feels instantaneous (<16ms)
    // while Flutter engine & background PTY cleanup complete cleanly.
    if (win != null) {
      if (_windowListenerId != null) {
        try {
          win.removeListener(_windowListenerId!);
        } catch (_) {}
        _windowListenerId = null;
      }
      try {
        win.hide();
      } catch (_) {}
    }
    _cleanupTray();

    // Never call synchronous `win.close()` (`native_window_close`) inside a
    // Flutter pointer/UI callback: on Windows' merged UI thread that triggers
    // synchronous `WM_CLOSE` / engine teardown while Dart is still on the stack.
    // Instead request an asynchronous embedder shutdown via ServicesBinding.
    Timer(Duration.zero, () async {
      try {
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      } catch (_) {
        exit(0);
      }
    });
    // Crisp safety net so hidden/tray exits terminate promptly without lingering
    Timer(const Duration(milliseconds: 250), () {
      exit(0);
    });
  }

  Window? _tryResolveWindow() {
    try {
      _window = WindowManager.instance.getCurrent();
      return _window;
    } catch (_) {
      return null;
    }
  }

  void _cleanupTray() {
    try {
      if (_trayIcon != null) {
        if (_trayListenerId != null) {
          _trayIcon!.removeListener(_trayListenerId!);
          _trayListenerId = null;
        }
        _trayIcon!.setVisible(false);
        _trayIcon!.dispose();
        _trayIcon = null;
      }
      for (final item in _menuItems) {
        item.dispose();
      }
      _menuItems.clear();
      _trayMenu?.dispose();
      _trayMenu = null;
      _trayImage?.dispose();
      _trayImage = null;
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_window != null && _windowListenerId != null) {
      try {
        _window!.removeListener(_windowListenerId!);
      } catch (_) {}
      _windowListenerId = null;
    }
    _cleanupTray();
  }
}
