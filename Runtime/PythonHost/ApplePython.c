// ApplePython.c — C bridge to the embedded CPython interpreter.
//
// See ApplePython.h for the contract. Notes for the first CI run:
//  * The BeeWare Python-Apple-support 3.13 xcframework is expected to
//    expose its headers as <Python/Python.h> once the framework is in
//    the target's framework search path (Xcode does this automatically
//    for an embedded xcframework). If the header is not found, the
//    header search path in project.yml is the first thing to check.
//  * The stdlib layout assumed here is the one CPython's own iOS build
//    documents: <Python.framework>/lib/python3.13. If the BeeWare
//    package lays it out differently, YiPythonInitialize prints the
//    paths it tried to stderr — read the first CI log and fix the
//    suffix below, do not guess.
//  * PyConfig isolated mode is used on purpose: no PYTHONPATH /
//    PYTHONHOME from the environment can leak in (there is none on
//    iOS anyway), and every search path is set explicitly here.
//  * The interpreter is initialised ONCE per process. CPython cannot be
//    re-initialised after Py_Finalize in the same process, so YiPlayer
//    never finalises it.
#include "ApplePython.h"

#include <Python/Python.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_initialized = 0;
static PyObject *g_bridgeModule = NULL; // spiders/_yi_bridge.py, imported once

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

int YiPythonInitialize(const char *frameworkPath,
                       const char *spidersDir,
                       const char *sitePackagesDir,
                       const char *documentsSpidersDir) {
    if (g_initialized) return 0;
    if (!frameworkPath || !spidersDir) {
        fprintf(stderr, "[YiPython] missing frameworkPath or spidersDir\n");
        return 1;
    }

    // The stdlib lives inside the framework slice, next to the binary.
    char stdlibPath[4096];
    snprintf(stdlibPath, sizeof(stdlibPath), "%s/lib/python3.13", frameworkPath);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.parse_argv = 0;
    config.site_import = 0; // no site.py: the requests stack is added by path below

    PyStatus status = PyConfig_SetBytesString(&config, &config.home, frameworkPath);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "[YiPython] cannot set home to %s\n", frameworkPath);
        PyConfig_Clear(&config);
        return 2;
    }
    status = PyConfig_SetBytesString(&config, &config.program_name, "YiPlayer");
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return 2;
    }

    // module_search_paths starts with the stdlib; everything else is
    // appended in priority order: user spiders first, then the bundled
    // spiders (pd.py + base/ + _yi_bridge.py), then site-packages.
    // Order matters: a user file named like a bundled one must win.
    if (addSearchPath(&config, stdlibPath) != 0 ||
        addSearchPath(&config, documentsSpidersDir) != 0 ||
        addSearchPath(&config, spidersDir) != 0 ||
        addSearchPath(&config, sitePackagesDir) != 0) {
        PyConfig_Clear(&config);
        return 3;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "[YiPython] Py_InitializeFromConfig failed: %s\n",
                status.err_msg ? status.err_msg : "(no message)");
        return 4;
    }

    // Import the thin Python-side bridge (spiders/_yi_bridge.py). It owns
    // spider caching, argument conversion and error wrapping, so this C
    // file never has to know a spider's interface.
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *bridge = PyImport_ImportModule("_yi_bridge");
    if (!bridge) {
        fprintf(stderr, "[YiPython] cannot import _yi_bridge (is spidersDir on sys.path?)\n");
        PyErr_Print();
        PyGILState_Release(gil);
        return 5;
    }
    g_bridgeModule = bridge; // intentionally leaked: lives for the process
    g_initialized = 1;
    PyGILState_Release(gil);
    fprintf(stderr, "[YiPython] interpreter ready (stdlib: %s)\n", stdlibPath);
    return 0;
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
