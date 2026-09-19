// Adapted from https://github.com/Rob--W/firefox-android-backup-restore
// for headless RDP automation: functions return their log output directly
// instead of console.log'ing it, and restore is split into apply + kill so
// the RDP connection can read the result before Firefox force-closes.

function system_exec(command, _internal_caller) {
  command = command.trim();
  const skip_fork = _internal_caller === system_exec_nofork;
  const { ctypes } = ChromeUtils.importESModule(
    "resource://gre/modules/ctypes.sys.mjs"
  );
  const libc = ctypes.open("libc.so");
  const fork = libc.declare("fork", ctypes.default_abi, ctypes.int);
  const exit = libc.declare("exit", ctypes.default_abi, ctypes.void_t, ctypes.int);
  const execv = libc.declare(
    "execl", ctypes.default_abi, ctypes.int,
    ctypes.char.ptr, ctypes.char.ptr, ctypes.char.ptr, ctypes.char.ptr, ctypes.char.ptr
  );
  const WEXITSTATUS = wstatus => (wstatus >> 8) & 0xFF;
  const waitpid = libc.declare(
    "waitpid", ctypes.default_abi, ctypes.int32_t,
    ctypes.int32_t, ctypes.int.ptr, ctypes.int
  );
  let rv = 0;
  try {
    if (!skip_fork) {
      rv = fork();
      if (rv === -1) throw new Error("fork() failed, errno=" + ctypes.errno);
    }
    if (rv === 0) {
      rv = execv("/bin/sh", "sh", "-c", command, ctypes.char.ptr(0));
      console.error("execv failed: " + rv + ", errno=" + ctypes.errno);
      if (!skip_fork) {
        rv = exit(ctypes.errno);
        throw new Error("exit() unexpectedly returned!!!");
      }
    } else {
      const status = ctypes.int();
      rv = waitpid(rv, status.address(), 0);
      if (rv === -1) throw new Error("waitpid failed, errno=" + ctypes.errno);
      rv = WEXITSTATUS(status.value);
    }
    return rv;
  } finally {
    libc.close();
  }
}

function system_exec_nofork(command) {
  return system_exec(command, system_exec_nofork);
}

// Like system_exec_check_output, but RETURNS the captured log text instead
// of console.log'ing it, so the RDP caller gets it as the eval result.
function fab_exec_capture(command) {
  const SHARED_HOME = android_path_public_appdata();
  const PUBLIC_LOG_FILE = SHARED_HOME + "/firefox-android-backup.log";
  const SHELL_CODE = `
mkdir -p '${SHARED_HOME}'
exec 2>'${PUBLIC_LOG_FILE}' 1>&2

${command}`;
  let rv = system_exec(SHELL_CODE);
  let output = "";
  try {
    const file = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
    file.initWithPath(PUBLIC_LOG_FILE);
    output = Cu.readUTF8File(file);
  } catch (e) {
    output = "(failed to read log: " + e + ")";
  }
  if (rv !== 0) {
    throw new Error("Process exited non-successfully, exit code " + rv + "\n" + output);
  }
  return output;
}

function android_path_private_appdata() {
  return safe_path(Services.env.get("GRE_HOME"));
}

function android_path_public_appdata() {
  const appid = Services.env.get("MOZ_ANDROID_PACKAGE_NAME");
  return safe_path("/sdcard/Android/data/" + appid);
}

function safe_path(path) {
  if (!/^\/((?![!"$'\\`])[ -~])+$/.test(path)) {
    throw new Error("Rejected unsafe path: " + path);
  }
  return path;
}

function fab_backup_create_v2(fabPort) {
  const APP_HOME = android_path_private_appdata();
  const SHELL_CODE = String.raw`
set -e -o pipefail
set -x
tar cz -C '${APP_HOME}' \
  shared_prefs files databases cache nimbus_data no_backup glean_data \
  | nc 127.0.0.1 ${fabPort}
echo "DONE: fab_backup_create_v2() finished."
`;
  return fab_exec_capture(SHELL_CODE);
}

function fab_backup_restore_apply_v2() {
  const APP_HOME = android_path_private_appdata();
  const SHARED_HOME = android_path_public_appdata();
  const BACKUP_TMP = APP_HOME + "/cache/firefox-android-backup.tmp";
  const TRASH_TMP = APP_HOME + "/cache/firefox-android-trash.tmp";
  const CACHE_TRASH_TMP = APP_HOME + "/firefox-android-cache-trash.tmp";
  const SHELL_CODE = String.raw`
set -ex
rm -rf '${BACKUP_TMP}' '${TRASH_TMP}' '${CACHE_TRASH_TMP}'
mkdir -p '${BACKUP_TMP}' '${TRASH_TMP}'
tar xz -C '${BACKUP_TMP}' -f '${SHARED_HOME}/firefox-android-backup.tar.gz'
cd '${BACKUP_TMP}'
for entry in * ; do
  [ "$entry" != lib ] || continue
  [ "$entry" != .nomedia ] || continue
  [ "$entry" != cache ] || continue
  mv '${APP_HOME}/'"$entry" '${TRASH_TMP}/'
  mv '${BACKUP_TMP}'/"$entry" '${APP_HOME}'
done
if [ -d '${BACKUP_TMP}/cache' ] ; then
  mv '${TRASH_TMP}' '${CACHE_TRASH_TMP}'
  mv '${APP_HOME}/cache' '${CACHE_TRASH_TMP}/'
  mv '${CACHE_TRASH_TMP}/cache/firefox-android-backup.tmp/cache' '${APP_HOME}/cache'
  mv '${CACHE_TRASH_TMP}' '${TRASH_TMP}'
fi
rm -rf '${TRASH_TMP}'
echo "DONE: fab_backup_restore_apply_v2() finished."
`;
  return fab_exec_capture(SHELL_CODE);
}

function fab_kill_app() {
  // Replaces the current process image; the app exits. Fire-and-forget:
  // the RDP connection will drop as a result, so callers should not
  // wait for a response after calling this.
  system_exec_nofork("exit 0");
}

function fab_cleanup_v2() {
  const SHARED_HOME = android_path_public_appdata();
  IOUtils.remove(SHARED_HOME + "/firefox-android-backup.log");
  IOUtils.remove(SHARED_HOME + "/firefox-android-backup.tar.gz");
}
