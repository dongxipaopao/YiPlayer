// NodeBridge.h — C entry point for the embedded Node.js runtime
// (jo32/nodejs-mobile, Node.js 26 LTS, V8 without JIT on iOS).
//
// The Swift side (NodeHost.swift) never touches Node directly: it
// starts the runtime once through this bridge and then talks to it
// over loopback HTTP (see Runtime/NodeHost/host.mjs). The bridge only
// owns the process-lifetime thread that runs Node.
//
// Why a C function, not Swift: node::Start is C++. The .mm file
// (NodeBridge.mm) calls it on a detached pthread, so Swift stays
// free of C++.
#ifndef YIPLAYER_NODE_BRIDGE_H
#define YIPLAYER_NODE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Start the embedded Node.js runtime on a background thread, running
///   node <mainJs> <controlFile> <relistenFile>
/// mainJs is the host script (Runtime/NodeHost/host.mjs in the bundle);
/// controlFile is where the host writes {"port": <n>, "token": "..."}
/// once its control server listens; relistenFile is appended to when
/// iOS takes the listening sockets back after a suspend (see host.mjs).
/// Returns 0 when the thread was started. Non-zero when Node was
/// already started: node::Start can only run ONCE per process, so a
/// second call is refused instead of crashing the app.
/// The call returns immediately; Node runs until the app exits.
/// NOTE: node::Start may terminate the process if Node itself fails
/// to start (e.g. the entry script is missing) — that is Node's own
/// behaviour, not something this bridge can catch.
int YiNodeStart(const char *mainJs,
                const char *controlFile,
                const char *relistenFile);

/// 1 once YiNodeStart has been called, 0 before.
int YiNodeIsRunning(void);

#ifdef __cplusplus
}
#endif

#endif /* YIPLAYER_NODE_BRIDGE_H */
