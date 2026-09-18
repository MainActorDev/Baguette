// ViewTreeProbe — dumps the app's own UIView hierarchy on request, without
// a debugger attach (the pause-free replacement for the lldb viewtree path).
//
// Transport (house pattern of VirtualMotion/VirtualNetwork):
//   request  /tmp/BaguetteViewTree-<udid>.json       — {id, bundleId}
//   response /tmp/BaguetteViewTree-<udid>.dump.json  — {id, bundleId, nodes…}
//
// The host (Crucible) rewrites the request file with a fresh id; the probe
// stat-polls it, and on a new id walks keyWindow.subviews on the MAIN
// thread and atomically writes the response. The app is never paused.
//
// This dylib is loaded into EVERY process launched in the simulator while
// the variable is armed — launchctl, SpringBoard, every app. The bundle
// filter in the constructor reads the intent file ONCE and installs the
// watcher only when the process's main bundle id matches, so every other
// process pays exactly one small file read.
//
// Diagnostics go to the unified log ONLY — never NSLog. This dylib loads
// into launchctl itself; stderr output from here can come back through the
// simulator's spawned-process channel as part of a value baguette is trying
// to read. Read these with:
//   xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.viewtree"'

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <os/lock.h>
#import <sys/stat.h>

static void VTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VTLog(NSString *format, ...) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("com.baguette.viewtree", "probe");
    });
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(logger, "%{public}s", message.UTF8String);
}

/// The request/response paths for *this* simulator.
///
/// Every simulator sees the host's `/tmp`, so a single shared file would
/// mean requesting a dump on one device replaced the intent an injected app
/// on another was still reading. `SIMULATOR_UDID` is set in every process
/// the simulator launches, so both sides derive the same per-device path.
static NSString *VTRequestPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *udid = getenv("SIMULATOR_UDID");
        path = udid ? [NSString stringWithFormat:@"/tmp/BaguetteViewTree-%s.json", udid] : nil;
    });
    return path;
}

static NSString *VTResponsePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *udid = getenv("SIMULATOR_UDID");
        path = udid ? [NSString stringWithFormat:@"/tmp/BaguetteViewTree-%s.dump.json", udid] : nil;
    });
    return path;
}

/// The last request id this probe has answered (or is answering). Guarded
/// because the poller and a main-thread dump could otherwise race on it.
static NSString *gAnsweredId;
static os_unfair_lock gIdLock = OS_UNFAIR_LOCK_INIT;
static BOOL gInstalled = NO;

/// YES once the constructor decided this process is the probe target and
/// installed the watcher. Exported on purpose: the house build script
/// rejects a dylib that exports nothing (an all-static dylib is how the
/// Homebrew empty-dylib bug hid), and it is a handy live diagnostic —
/// `expr -- (int)VTProbeInstalled()` in lldb proves injection took.
BOOL VTProbeInstalled(void) {
    return gInstalled;
}

/// How often the request file is stat'ed. A dump is a rare, human-triggered
/// event; 0.1s poll cost is the same cadence VirtualNetwork conditions on.
static const double kPollInterval = 0.1;

/// Monotonic clock for intervals — wall time can step backwards (NTP, the
/// tester changing the simulator's date) and stall the poll.
static double VTNow(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

/// Reads the current request, or nil when absent/unparseable.
static NSDictionary *VTCurrentRequest(void) {
    NSString *path = VTRequestPath();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]] || error) return nil;
    return json;
}

__attribute__((constructor)) static void ViewTreeProbeInit(void) {
    NSString *requestPath = VTRequestPath();
    if (!requestPath) {
        // Not a simulator process (host build of something linked us in) —
        // nothing to do, and nowhere safe to watch.
        return;
    }

    // The bundle filter: one intent read decides whether this process is
    // the probe's target. Every non-matching process stops here for good.
    NSDictionary *request = VTCurrentRequest();
    if (!request) {
        // No intent armed for this simulator at the moment we loaded. The
        // host arms BEFORE relaunching the app, so this is the normal state
        // for every process that isn't the target — including launchctl
        // spawned to read the variable itself.
        return;
    }
    NSString *wanted = request[@"bundleId"];
    if (![wanted isKindOfClass:[NSString class]] || wanted.length == 0) return;

    NSBundle *main = [NSBundle mainBundle];
    NSString *bundleId = main.bundleIdentifier;
    if (![bundleId isEqualToString:wanted]) return;

    VTLog(@"[ViewTreeProbe] installed in %@ — watching %@", bundleId, requestPath);
    gInstalled = YES;
    // T2: install the stat-poll watcher here.
    (void)kPollInterval;
    (void)VTNow;
    (void)VTResponsePath;
    (void)gAnsweredId;
    (void)gIdLock;
}
