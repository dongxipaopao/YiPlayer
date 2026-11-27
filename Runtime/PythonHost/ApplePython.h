// ApplePython.h — C bridge between Swift and the embedded CPython
// interpreter (BeeWare Python-Apple-support, Python 3.13).
//
// Design (Yingxia Docs/python-runtime-plan.md: "C bridge
// Runtime/AppleRuntime/Native/ApplePython.c, TVPythonRequest"):
// one interpreter, one serial caller (Swift serialises all calls on a
// single queue and this bridge holds the GIL for the duration of each
// call). The bridge itself stays thin: initialisation + one
// request/response function. All spider logic lives in Python
// (spiders/_yi_bridge.py), so the C code never has to know a spider's
// methods, arguments or result shapes.
//
// Memory: YiPythonCallSpider returns a malloc'd UTF-8 JSON string.
// Swift must free it with YiPythonFreeString. A NULL return means the
// bridge itself failed before Python could even answer (interpreter
// dead, _yi_bridge missing); Swift turns that into SourceError.
#ifndef YIPLAYER_APPLE_PYTHON_H
#define YIPLAYER_APPLE_PYTHON_H

#ifdef __cplusplus
extern "C" {
#endif

/// Initialise the interpreter once. Paths are absolute UTF-8 paths.
///   frameworkPath      — <App>.app/Frameworks/Python.framework
///                        (the stdlib lives in <frameworkPath>/lib/python3.13)
///   spidersDir         — bundle Resources/spiders (pd.py, base/, _yi_bridge.py)
///   sitePackagesDir    — bundle Resources/spiders/site-packages
///                        (pure-Python requests stack, installed by CI)
///   documentsSpidersDir— Documents/spiders (user-imported .py files)
/// Returns 0 on success, non-zero with an error printed to stderr.
/// Safe to call repeatedly: later calls are no-ops.
int YiPythonInitialize(const char *frameworkPath,
                       const char *spidersDir,
                       const char *sitePackagesDir,
                       const char *documentsSpidersDir);

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
