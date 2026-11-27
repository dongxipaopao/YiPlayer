// NodeBridge.mm — Objective-C++ wrapper around node::Start.
//
// This is the embedding entry point nodejs-mobile is built for: the
// framework's node::Start runs a full Node.js on a thread of the app's
// own, with V8 in JIT-less mode (the only mode iOS allows). The React
// Native / Cordova plugins for nodejs-mobile start Node exactly this
// way; YiPlayer does the same, then drives it over loopback HTTP.
//
// Build note (verify on the first CI run): this file includes
// <node/node.h> from the NodeMobile.xcframework. project.yml sets
// HEADER_SEARCH_PATHS to the framework's Headers directory for both
// the device slice (ios-arm64) and the simulator slice
// (ios-arm64-simulator). If the xcframework lays its headers out
// differently, the first CI log will name the missing header — fix
// the search path there, do not change this file's include.
#import "NodeBridge.h"

#include <node/node.h>

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
    // node::Start returns the process exit code; on iOS there is no
    // parent to report it to, so the value is dropped.
    node::Start(argc, const_cast<char **>(argv));
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
