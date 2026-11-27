// NodeBridge.mm — Objective-C++ wrapper around node_start().
//
// This is the embedding entry point nodejs-mobile is built for: the
// framework's node_start() runs a full Node.js on a thread of the
// app's own, with V8 in JIT-less mode (the only mode iOS allows).
// The React Native / Cordova plugins for nodejs-mobile start Node
// exactly this way; YiPlayer does the same, then drives it over
// loopback HTTP.
//
// Verified 2026-11-27 against the real
// nodejs-mobile-v26.13.0-apple.zip: the xcframework ships ONLY
// NodeMobile.h, which declares `int node_start(int argc, char
// *argv[])`. There is NO node/node.h anywhere in the archive, so
// do NOT include <node/node.h> or node::Start here — that was the
// run #19 build failure. <NodeMobile/NodeMobile.h> resolves through
// FRAMEWORK_SEARCH_PATHS ($(PROJECT_DIR)/vendor).
#import "NodeBridge.h"

#import <NodeMobile/NodeMobile.h>

#include <pthread.h>
#include <string>

namespace {

struct NodeArgs {
    std::string mainJs;
    std::string controlFile;
    std::string relistenFile;
};

bool g_started = false;

void *runNode(void *raw) {
    std::unique_ptr<NodeArgs> args(static_cast<NodeArgs *>(raw));
    // node::Start expects argv like a command line: argv[0] is the
    // program name, then the entry script and its arguments.
    const char *argv[] = {
        "node",
        args->mainJs.c_str(),
        args->controlFile.c_str(),
        args->relistenFile.c_str(),
        nullptr,
    };
    const int argc = 4;
    // Blocks until Node exits (normally: when the app exits).
    // node_start returns the process exit code; on iOS there is no
    // parent to report it to, so the value is dropped.
    node_start(argc, const_cast<char **>(argv));
    return nullptr;
}

} // namespace

int YiNodeStart(const char *mainJs, const char *controlFile, const char *relistenFile) {
    if (g_started) return 1;
    if (!mainJs || !controlFile || !relistenFile) return 2;
    NodeArgs *args = new NodeArgs{std::string(mainJs), std::string(controlFile),
                                  std::string(relistenFile)};
    pthread_t thread;
    if (pthread_create(&thread, nullptr, &runNode, args) != 0) {
        delete args;
        return 3;
    }
    pthread_detach(thread);
    g_started = true;
    return 0;
}

int YiNodeIsRunning(void) {
    return g_started ? 1 : 0;
}
