// ApplePython.h — C bridge between Swift and the embedded CPython
// interpreter (BeeWare Python-Apple-support, Python 3.13).
//
// Design (borrowed from tvbox-silicon Docs/python-runtime-plan.md:
// "C bridge Runtime/AppleRuntime/Native/ApplePython.c,
// TVPythonRequest"): one interpreter, one C entry point, and the
// same serial-caller shape. The bridge itself stays thin:
// initialisation + one request/response function. All spider logic
// lives in Python (spiders/_yi_bridge.py), so the C code never has
// to know a spider's methods, arguments or result shapes.
//
// Memory: YiPythonCallSpider returns a malloc'd UTF-8 JSON string.
// Swift must free it with YiPythonFreeString. A NULL return means the
// bridge itself failed before Python could even answer (interpreter
// dead, _yi_bridge missing); Swift turns that into SourceError.
//
// STDLIB LAYOUT — verified 2026-11-27 against the real BeeWare
// 3.13-b18 package (Python-3.13-iOS-support.b18.tar.gz):
//   <xcframework>/lib/python3.13/                        pure-Python stdlib
//   <xcframework>/ios-arm64/lib-arm64/python3.13/lib-dynload/
//                                                        device .so modules
//   <xcframework>/ios-arm64/Python.framework/            binary + headers ONLY
// Xcode copies only the .framework into the .app, so the stdlib is
// staged into the bundle by Scripts/fetch-python.sh as
// python-stdlib/python3.13/ (with lib-dynload/ inside it) and
// project.yml adds vendor/python-stdlib as a folder reference.
// v2.0.0 assumed <Python.framework>/lib/python3.13 instead, which
// does not exist anywhere — that is why Py_InitializeFromConfig
// failed with error code 4 ("No module named 'encodings'") in the
// v2.0.0 build. Do NOT "fix" this back to a framework-relative path.
#ifndef YIPLAYER_APPLE_PYTHON_H
#define YIPLAYER_APPLE_PYTHON_H

#ifdef __cplusplus
extern "C" {
#endif

/// Initialise the interpreter once. Paths are absolute UTF-8 paths.
///   frameworkPath      — <App>.app/Frameworks/Python.framework
///                        (used as PyConfig home only; the stdlib does
///                        NOT live under it — see the layout note above)
///   stdlibDir          — <App>.app/python-stdlib/python3.13
///                        (must contain os.py and encodings/__init__.py)
///   dynloadDir         — <stdlibDir>/lib-dynload
///                        (device .so extension modules: _socket, _ssl, ...)
///   spidersDir         — bundle Resources/spiders (pd.py, base/, _yi_bridge.py)
///   sitePackagesDir    — bundle Resources/spiders/site-packages
///                        (pure-Python requests stack, installed by CI)
///   documentsSpidersDir— Documents/spiders (user-imported .py files)
/// Returns 0 on success, non-zero with a message recorded for
/// YiPythonLastError (and printed to stderr). Safe to call
/// repeatedly: the first attempt's result is cached and later calls
/// return it without touching CPython again. This matters: a failed
/// Py_InitializeFromConfig leaves the runtime half-initialised
/// (CPython 3.13 pyinit_core_reconfigure), and re-entering it from
/// another thread fails with "failed to read thread state" — v2.1.0
/// retried on every call and only ever showed that misleading
/// second error. See ApplePython.c.
int YiPythonInitialize(const char *frameworkPath,
                       const char *stdlibDir,
                       const char *dynloadDir,
                       const char *spidersDir,
                       const char *sitePackagesDir,
                       const char *documentsSpidersDir);

/// The last initialisation failure, as a human-readable string
/// (includes the PyStatus message and the paths that were tried).
/// Empty string when there was no failure. The pointer stays valid
/// for the life of the process; copy it if you need it longer.
const char *YiPythonLastError(void);

/// Call one spider method and get the JSON answer.
///   scriptPath — absolute path of the spider file (e.g. pd.py)
///   method     — spider method name ("homeVideoContent", "categoryContent", ...)
///   argsJson   — JSON array of positional arguments, e.g. ["movie", 1, {}, {}]
/// Returns a malloc'd string: {"ok": true, "result": <anything>} or
/// {"ok": false, "error": "<message>"}. Free with YiPythonFreeString.
/// NULL only when the interpreter is not initialised or is dead.
char *YiPythonCallSpider(const char *scriptPath,
                         const char *method,
                         const char *argsJson);

/// Free a string returned by YiPythonCallSpider.
void YiPythonFreeString(char *str);

/// 1 when the interpreter is up, 0 otherwise. Swift uses this to decide
/// whether the "iOS 暂不支持 Python 运行时" fallback applies.
int YiPythonIsReady(void);

#ifdef __cplusplus
}
#endif

#endif /* YIPLAYER_APPLE_PYTHON_H */
