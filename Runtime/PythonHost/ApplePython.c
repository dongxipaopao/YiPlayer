// ApplePython.c — C bridge to the embedded CPython interpreter.
//
// See ApplePython.h for the contract. Notes:
//  * The BeeWare Python-Apple-support 3.13 xcframework is expected to
//    expose its headers as <Python/Python.h> once the framework is in
//    the target's framework search path (Xcode does this automatically
//    for an embedded xcframework). If the header is not found, the
//    header search path in project.yml is the first thing to check.
//  * STDLIB LAYOUT (verified 2026-11-27 against the real 3.13-b18
//    tarball — see ApplePython.h): the stdlib lives at the
//    xcframework ROOT (lib/python3.13), the device extension modules
//    in ios-arm64/lib-arm64/python3.13/lib-dynload, and
//    Python.framework holds ONLY the binary + headers. CI stages
//    both into the bundle as python-stdlib/ (Scripts/fetch-python.sh);
//    the stdlib path is passed in, never derived from the framework
//    path. v2.0.0 derived it as <framework>/lib/python3.13 and
//    initialisation failed with error code 4 on every device.
//  * PyConfig isolated mode is used on purpose: no PYTHONPATH /
//    PYTHONHOME from the environment can leak in (there is none on
//    iOS anyway), and every search path is set explicitly here.
//  * The interpreter is initialised ONCE per process. CPython cannot be
//    re-initialised after Py_Finalize in the same process, so YiPlayer
//    never finalises it.
//  * v2.1.1 — WHY INIT IS EXACTLY-ONCE (read this before touching
//    YiPythonInitialize): CPython 3.13's Py_InitializeFromConfig may
//    only be attempted once per process in practice. Its core init
//    (Python/pylifecycle.c: pyinit_config) sets
//    runtime->core_initialized = 1 as soon as the interpreter object
//    exists; if the later main init (pyinit_main) then fails, the
//    runtime is left half-initialised. A second call takes the
//    reconfigure branch (pyinit_core -> pyinit_core_reconfigure),
//    whose first step reads the current thread's thread state with
//    _PyThreadState_GET(); on any thread other than the one that ran
//    the first attempt that is NULL, and the call fails with
//    "failed to read thread state" (pylifecycle.c:475). v2.1.0
//    retried on every Discover/Search/Home call, from arbitrary
//    Swift executor threads — so after the first failure every later
//    call failed with exactly that message, and the real first
//    failure was never visible. The fix, following tvbox-silicon's
//    ApplePython.c (dispatch_once + a cached `failure` string that
//    every later request answers with): one attempt, on one thread,
//    and the outcome — success or the first failure — is cached
//    forever. Swift (EmbeddedPythonHost) does the same on its side.
//  * Reference implementation read 2026-11-27 (tvbox-silicon,
//    dongxipaopao fork): Runtime/AppleRuntime/Native/ApplePython.c,
//    Sources/TVCore/EmbeddedPythonHost.swift,
//    Sources/TVCore/EmbeddedNodeHost.swift, Docs/python-runtime-plan.md.
//    Their bridge targets CPython 3.14's PEP 741 PyInitConfig API
//    (opaque config, dlsym'd at runtime), which BeeWare 3.13 does not
//    export — so their C file cannot be copied verbatim here; the
//    design was ported instead (once-only start, cached failure,
//    config fields below, SIGPIPE/SIGXFSZ ignored, thread stack
//    size for Node — see NodeBridge.mm). No tvbox-silicon code is
//    copied verbatim into this file. License consequence: if
//    tvbox-silicon / MarcoMovie code is ever copied verbatim into
//    YiPlayer, YiPlayer must be treated as GPL-3.0 (keep the
//    original license headers and attribution, and provide the
//    corresponding source when distributing the IPA) — see
//    BUILD_NOTES.md.
#include "ApplePython.h"

#include <Python/Python.h>

#include <mach-o/dyld.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_initialized = 0;
// v2.1.1: exactly-once guard. A failed Py_InitializeFromConfig
// leaves CPython half-initialised (see the header comment); calling
// it again — especially from another thread — fails with
// "failed to read thread state" and hides the real first error.
// So the attempt itself is cached, not just success.
static int g_initAttempted = 0;
static int g_initResult = -1;
static PyObject *g_bridgeModule = NULL; // spiders/_yi_bridge.py, imported once

// Last initialisation failure, for YiPythonLastError: the PyStatus
// message plus the paths that were tried. v2.0.0 only surfaced
// "错误码 4", which said nothing about WHY init failed.
static char g_lastError[2048] = "";

static void setLastError(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_lastError, sizeof(g_lastError), fmt, args);
    va_end(args);
    fprintf(stderr, "[YiPython] %s\n", g_lastError);
}

const char *YiPythonLastError(void) {
    return g_lastError;
}

// Append one search path to a PyConfig. module_search_paths is a
// PyWideStringList (not a single string), so it needs
// PyWideStringList_Append with a decoded wchar_t string.
static int addSearchPath(PyConfig *config, const char *path) {
    wchar_t *wpath = Py_DecodeLocale(path, NULL);
    if (!wpath) {
        fprintf(stderr, "[YiPython] cannot decode search path %s\n", path);
        return -1;
    }
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wpath);
    PyMem_RawFree(wpath);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "[YiPython] cannot add search path %s\n", path);
        return -1;
    }
    return 0;
}

static int initializeInner(const char *frameworkPath,
                           const char *stdlibDir,
                           const char *dynloadDir,
                           const char *spidersDir,
                           const char *sitePackagesDir,
                           const char *documentsSpidersDir) {
    if (g_initialized) return 0;
    if (!frameworkPath || !stdlibDir || !spidersDir) {
        setLastError("missing frameworkPath, stdlibDir or spidersDir");
        return 1;
    }

    // The stdlib is a bundle resource (python-stdlib/python3.13),
    // staged by Scripts/fetch-python.sh — NOT inside the framework.
    // Fail fast with the exact path when it is absent, so the UI can
    // say what is missing instead of a bare error code.
    char probe[4096];
    snprintf(probe, sizeof(probe), "%s/os.py", stdlibDir);
    FILE *osPy = fopen(probe, "r");
    if (!osPy) {
        setLastError("stdlib not found at %s (no os.py — python-stdlib was not bundled)", stdlibDir);
        return 1;
    }
    fclose(osPy);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.parse_argv = 0;
    config.site_import = 0; // no site.py: the requests stack is added by path below
    // v2.1.1, ported from tvbox-silicon's configure() (adapted from
    // PEP 741 PyInitConfig options to the 3.13 PyConfig fields):
    // no bytecode files in the signed read-only bundle, no signal
    // handlers installed by the interpreter (an app's Python must
    // not own signals), UTF-8 filesystem encoding.
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    // utf8_mode lives on PyPreConfig, NOT PyConfig (3.13): setting it
    // on PyConfig does not compile. Pre-initialize with an isolated
    // preconfig instead. This runs once (the once-guard above), which
    // is required — Py_PreInitialize must not be called twice.
    {
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        PyStatus pre = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(pre)) {
            setLastError("Py_PreInitialize failed: %s",
                         pre.err_msg ? pre.err_msg : "(no message)");
            return 2;
        }
    }
    // The app executable, so CPython's path computation has a real
    // anchor (tvbox-silicon sets this too). stdlib_dir above stays
    // the authority for where the stdlib lives.
    PyStatus status;
    {
        char executable[4096];
        uint32_t size = sizeof executable;
        if (_NSGetExecutablePath(executable, &size) == 0) {
            status = PyConfig_SetBytesString(&config, &config.executable, executable);
            if (PyStatus_Exception(status)) {
                setLastError("cannot set executable to %s: %s",
                             executable, status.err_msg ? status.err_msg : "(no message)");
                PyConfig_Clear(&config);
                return 2;
            }
        }
    }
    // A write to a closed socket (the player leaving, a server
    // hanging up) must raise BrokenPipeError in the spider, not kill
    // the app. tvbox-silicon's ApplePython.c does the same.
    signal(SIGPIPE, SIG_IGN);
    signal(SIGXFSZ, SIG_IGN);

    status = PyConfig_SetBytesString(&config, &config.home, frameworkPath);
    if (PyStatus_Exception(status)) {
        setLastError("cannot set home to %s: %s",
                     frameworkPath, status.err_msg ? status.err_msg : "(no message)");
        PyConfig_Clear(&config);
        return 2;
    }
    status = PyConfig_SetBytesString(&config, &config.program_name, "YiPlayer");
    if (PyStatus_Exception(status)) {
        setLastError("cannot set program_name: %s",
                     status.err_msg ? status.err_msg : "(no message)");
        PyConfig_Clear(&config);
        return 2;
    }
    // Point the interpreter at the bundled stdlib explicitly (the
    // field exists since CPython 3.11; it is what the bootstrap uses
    // to find encodings when module_search_paths is set by hand).
    status = PyConfig_SetBytesString(&config, &config.stdlib_dir, stdlibDir);
    if (PyStatus_Exception(status)) {
        setLastError("cannot set stdlib_dir to %s: %s",
                     stdlibDir, status.err_msg ? status.err_msg : "(no message)");
        PyConfig_Clear(&config);
        return 2;
    }

    // module_search_paths starts with the stdlib; everything else is
    // appended in priority order: user spiders first, then the bundled
    // spiders (pd.py + base/ + _yi_bridge.py), then site-packages.
    // Order matters: a user file named like a bundled one must win.
    // lib-dynload goes right after the stdlib so the C extension
    // modules (_socket, _ssl, _hashlib, ...) resolve.
    if (addSearchPath(&config, stdlibDir) != 0 ||
        (dynloadDir && addSearchPath(&config, dynloadDir) != 0) ||
        addSearchPath(&config, documentsSpidersDir) != 0 ||
        addSearchPath(&config, spidersDir) != 0 ||
        addSearchPath(&config, sitePackagesDir) != 0) {
        setLastError("cannot add search paths (stdlib %s, dynload %s)",
                     stdlibDir, dynloadDir ? dynloadDir : "(none)");
        PyConfig_Clear(&config);
        return 3;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        setLastError("Py_InitializeFromConfig failed (stdlib %s): %s",
                     stdlibDir, status.err_msg ? status.err_msg : "(no message)");
        return 4;
    }

    // Import the thin Python-side bridge (spiders/_yi_bridge.py). It owns
    // spider caching, argument conversion and error wrapping, so this C
    // file never has to know a spider's interface.
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *bridge = PyImport_ImportModule("_yi_bridge");
    if (!bridge) {
        setLastError("cannot import _yi_bridge (is spidersDir %s on sys.path?)", spidersDir);
        PyErr_Print();
        PyGILState_Release(gil);
        return 5;
    }
    g_bridgeModule = bridge; // intentionally leaked: lives for the process
    g_initialized = 1;
    PyGILState_Release(gil);
    fprintf(stderr, "[YiPython] interpreter ready (stdlib: %s)\n", stdlibDir);
    return 0;
}

// The public entry point. Exactly-once, like tvbox-silicon's
// dispatch_once_f(&started, ...) in TVPythonRequest: the first
// attempt's result is cached and every later call returns it without
// touching CPython again. A failed Py_InitializeFromConfig leaves
// the runtime half-initialised (CPython 3.13
// Python/pylifecycle.c: pyinit_core / pyinit_core_reconfigure), so
// re-entering it — especially from another thread — fails with
// "failed to read thread state" and hides the real first error.
// The cached failure keeps the first, true reason visible via
// YiPythonLastError.
int YiPythonInitialize(const char *frameworkPath,
                       const char *stdlibDir,
                       const char *dynloadDir,
                       const char *spidersDir,
                       const char *sitePackagesDir,
                       const char *documentsSpidersDir) {
    if (g_initialized) return 0;
    if (g_initAttempted) return g_initResult;
    g_initAttempted = 1;
    g_initResult = initializeInner(frameworkPath, stdlibDir, dynloadDir,
                                   spidersDir, sitePackagesDir,
                                   documentsSpidersDir);
    return g_initResult;
}

int YiPythonIsReady(void) {
    return g_initialized && g_bridgeModule != NULL;
}

char *YiPythonCallSpider(const char *scriptPath,
                         const char *method,
                         const char *argsJson) {
    if (!YiPythonIsReady() || !scriptPath || !method || !argsJson) return NULL;

    char *out = NULL;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *fn = PyObject_GetAttrString(g_bridgeModule, "call_spider");
    if (fn && PyCallable_Check(fn)) {
        PyObject *result = PyObject_CallFunction(fn, "sss", scriptPath, method, argsJson);
        if (result) {
            const char *text = PyUnicode_AsUTF8(result);
            if (text) out = strdup(text);
            Py_DECREF(result);
        } else {
            // The bridge itself crashed (it should never throw — it wraps
            // everything into {"ok": false}). Print the traceback so the
            // first CI log shows it, and return a JSON error instead of NULL.
            PyErr_Print();
            const char *fallback = "{\"ok\": false, \"error\": \"Python bridge failed unexpectedly\"}";
            out = strdup(fallback);
        }
        Py_DECREF(fn);
    }
    PyGILState_Release(gil);
    return out;
}

void YiPythonFreeString(char *str) {
    free(str);
}
