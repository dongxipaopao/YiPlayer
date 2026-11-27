# _yi_bridge.py — Python side of the YiPlayer CPython bridge.
#
# The C bridge (ApplePython.c) only knows one function: call_spider().
# Everything spider-shaped lives here: loading a spider file, keeping
# one Spider instance per file, calling its methods, and converting
# arguments/results to/from JSON. The C code never has to know what a
# spider is, and Swift never has to know how Python works.
#
# Contract with Swift (EmbeddedPythonHost.swift):
#   call_spider(script_path, method, args_json) -> str
#   args_json: JSON array of positional arguments.
#   Returns a JSON string: {"ok": true, "result": <anything>} or
#   {"ok": false, "error": "<message>"}. Never raises.
#   Results are serialised with json.dumps(..., default=str): a spider
#   that returns a non-JSON value (e.g. a datetime) degrades to its
#   str() form instead of crashing the call.
import importlib.util
import json
import os
import sys
import threading

# One Spider instance per script file, guarded by one lock: CPython has
# a single interpreter and Swift serialises calls anyway, but the lock
# makes a second caller impossible rather than merely unlikely.
_lock = threading.Lock()
_instances = {}
_counter = [0]


def _load_instance(script_path):
    """Load a spider file and instantiate its Spider class (cached)."""
    if script_path in _instances:
        return _instances[script_path]
    if not os.path.isfile(script_path):
        raise FileNotFoundError("spider file not found: {}".format(script_path))
    _counter[0] += 1
    module_name = "yi_spider_{}".format(_counter[0])
    spec = importlib.util.spec_from_file_location(module_name, script_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load spider file: {}".format(script_path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    spider_cls = getattr(module, "Spider", None)
    if spider_cls is None:
        raise AttributeError("spider file has no Spider class: {}".format(script_path))
    instance = spider_cls()
    try:
        instance.init("")
    except Exception:
        # init() is best-effort here: pd.py's init only reads the extend
        # JSON and sets host/name/ua. A spider that cannot init with ""
        # is still usable for read-only calls; the real error will
        # surface on the first method call, with its own message.
        pass
    _instances[script_path] = instance
    return instance


def _to_jsonable(value):
    """Best-effort conversion to something json.dumps accepts."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (list, tuple)):
        return [_to_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _to_jsonable(v) for k, v in value.items()}
    return str(value)


def call_spider(script_path, method, args_json):
    """Call one spider method. Never raises; always returns a JSON string."""
    try:
        try:
            args = json.loads(args_json) if args_json else []
        except Exception:
            return json.dumps({"ok": False, "error": "bad args JSON"}, ensure_ascii=False)
        if not isinstance(args, list):
            args = [args]
        with _lock:
            instance = _load_instance(script_path)
            fn = getattr(instance, method, None)
            if fn is None or not callable(fn):
                return json.dumps(
                    {"ok": False,
                     "error": "spider has no method '{}'".format(method)},
                    ensure_ascii=False)
            result = fn(*args)
        return json.dumps({"ok": True, "result": _to_jsonable(result)},
                          ensure_ascii=False)
    except Exception as e:
        return json.dumps({"ok": False, "error": "{}: {}".format(type(e).__name__, e)},
                          ensure_ascii=False)
