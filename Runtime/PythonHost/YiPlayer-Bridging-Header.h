// YiPlayer-Bridging-Header.h — Swift ↔ C bridging header for the
// embedded runtimes. XcodeGen sets SWIFT_OBJC_BRIDGING_HEADER to this
// file (see project.yml). It only exposes the two tiny C APIs the app
// needs; the runtimes themselves stay behind their Swift wrappers
// (EmbeddedPythonHost / NodeHost).
#import "ApplePython.h"
#import "NodeBridge.h"
