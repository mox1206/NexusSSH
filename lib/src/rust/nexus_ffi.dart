// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:nexus_ssh/src/rust/nexus_ffi.dart')
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

typedef DartOutputCallbackNative = Void Function(
  Pointer<Utf8> sessionId,
  Pointer<Uint8> dataPtr,
  Size dataLen,
);

typedef DartStatusCallbackNative = Void Function(Pointer<Utf8> eventJson);

@Native<
  Void Function(
    Pointer<NativeFunction<DartOutputCallbackNative>>,
    Pointer<NativeFunction<DartStatusCallbackNative>>,
  )
>()
external void nexus_register_callbacks(
  Pointer<NativeFunction<DartOutputCallbackNative>> outputCb,
  Pointer<NativeFunction<DartStatusCallbackNative>> statusCb,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_init_core(Pointer<Utf8> dataDir);

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_list_hosts();

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_upsert_host(Pointer<Utf8> profileJson);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_delete_host(Pointer<Utf8> hostId);

// --- Snippets ---

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_list_snippets();

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_upsert_snippet(Pointer<Utf8> snippetJson);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_delete_snippet(Pointer<Utf8> snippetId);

// --- Known Hosts (TOFU) ---

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint8, Uint8)>()
external Pointer<Utf8> nexus_respond_host_key(
  Pointer<Utf8> requestId,
  int accept,
  int persist,
);

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_list_known_hosts();

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_delete_known_host(Pointer<Utf8> hostKey);

// --- App Lock ---

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_get_app_lock_config();

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint8, Uint8, Int32)>()
external Pointer<Utf8> nexus_set_app_lock_passcode(
  Pointer<Utf8> passcode,
  int biometricsEnabled,
  int lockOnStartup,
  int autoLockMinutes,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_verify_app_lock_passcode(Pointer<Utf8> passcode);

@Native<Pointer<Utf8> Function(Uint8, Uint8, Int32)>()
external Pointer<Utf8> nexus_update_app_lock_settings(
  int biometricsEnabled,
  int lockOnStartup,
  int autoLockMinutes,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint8)>()
external Pointer<Utf8> nexus_disable_app_lock(
  Pointer<Utf8> currentPasscode,
  int bypassVerified,
);

// --- SFTP & Server Telemetry ---

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(isLeaf: false)
external Pointer<Utf8> nexus_sftp_list_dir(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> path,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(isLeaf: false)
external Pointer<Utf8> nexus_sftp_mkdir(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> path,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  isLeaf: false,
)
external Pointer<Utf8> nexus_sftp_rename(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint8)>(
  isLeaf: false,
)
external Pointer<Utf8> nexus_sftp_delete(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> path,
  int isDir,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32)>(
  isLeaf: false,
)
external Pointer<Utf8> nexus_sftp_chmod(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> path,
  int modeOctal,
);

@Native<
  Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
>(isLeaf: false)
external Pointer<Utf8> nexus_sftp_download(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> transferId,
  Pointer<Utf8> remotePath,
  Pointer<Utf8> localPath,
);

@Native<
  Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
>(isLeaf: false)
external Pointer<Utf8> nexus_sftp_upload(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> transferId,
  Pointer<Utf8> localPath,
  Pointer<Utf8> remotePath,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(isLeaf: false)
external Pointer<Utf8> nexus_fetch_server_metrics(Pointer<Utf8> sessionId);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint32)>(isLeaf: false)
external Pointer<Utf8> nexus_fetch_remote_history(
  Pointer<Utf8> sessionId,
  int maxEntries,
);

// --- Helpers & WebDAV ---

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_parse_quick_connect(Pointer<Utf8> expr);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>()
external Pointer<Utf8> nexus_inspect_private_key(
  Pointer<Utf8> pemContent,
  Pointer<Utf8> filePath,
  Pointer<Utf8> passphrase,
);

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_discover_local_keys();

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_get_webdav_config();

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> nexus_save_webdav_config(Pointer<Utf8> configJson);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(isLeaf: false)
external Pointer<Utf8> nexus_test_webdav(Pointer<Utf8> configJson);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(isLeaf: false)
external Pointer<Utf8> nexus_sync_webdav(
  Pointer<Utf8> configJsonOrEmpty,
  Pointer<Utf8> modeStr,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Uint32)>(isLeaf: false)
external Pointer<Utf8> nexus_test_connection(
  Pointer<Utf8> profileJson,
  int timeoutSecs,
);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint32, Uint32)>()
external Pointer<Utf8> nexus_session_connect(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> profileJson,
  int cols,
  int rows,
);

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> nexus_list_local_shells();

@Native<
  Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Uint32,
    Uint32,
  )
>()
external Pointer<Utf8> nexus_session_connect_local(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> shellProgram,
  Pointer<Utf8> cwd,
  int cols,
  int rows,
);

@Native<Int32 Function(Pointer<Utf8>, Pointer<Uint8>, Size)>()
external int nexus_session_write(
  Pointer<Utf8> sessionId,
  Pointer<Uint8> dataPtr,
  int dataLen,
);

@Native<Int32 Function(Pointer<Utf8>)>()
external int nexus_session_fill_sudo_password(Pointer<Utf8> sessionId);

@Native<Int32 Function(Pointer<Utf8>, Uint32, Uint32, Uint32, Uint32)>()
external int nexus_session_resize(
  Pointer<Utf8> sessionId,
  int cols,
  int rows,
  int pixelWidth,
  int pixelHeight,
);

@Native<Int32 Function(Pointer<Utf8>)>()
external int nexus_session_disconnect(Pointer<Utf8> sessionId);

@Native<Void Function()>()
external void nexus_prepare_shutdown();

@Native<Void Function(Pointer<Utf8>)>()
external void nexus_free_string(Pointer<Utf8> ptr);

@Native<Void Function(Pointer<Uint8>, Size)>()
external void nexus_free_bytes(Pointer<Uint8> ptr, int len);
