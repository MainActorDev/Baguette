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

static void VTInstallWatcher(void);

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

    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
    if (![bundleId isEqualToString:wanted]) return;

    VTLog(@"[ViewTreeProbe] installed in %@ — watching %@", bundleId, requestPath);
    gInstalled = YES;
    VTInstallWatcher();
}

#pragma mark - Dump

/// keyWindow resolved the way that works headless on modern iOS: the KVC
/// chain pinned by the lldb viewtree spike. Direct `keyWindow` is a
/// deprecated-symbol compile error inside lldb's parser; the KVC form is
/// the same call without the deprecation tripwire, and identical at runtime.
static UIWindow *VTKeyWindow(void) {
    id scene = [[UIApplication sharedApplication]
        valueForKey:@"connectedScenes"];
    scene = [scene anyObject];
    return [scene valueForKey:@"keyWindow"];
}

/// First superclass whose name starts with `UI` — the "baseClass"
/// recursiveDescription prints for app-specific classes, derived the same
/// way here so both sources agree on the vocabulary.
static NSString *VTBaseClass(UIView *view) {
    for (Class cls = class_getSuperclass(object_getClass(view));
         cls != NULL;
         cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if ([name hasPrefix:@"UI"]) return name;
    }
    return nil;
}

/// The text a view exposes to a human reading a tree — UILabel's text, a
/// button's title. recursiveDescription prints `text = '…'` for exactly
/// these; parity here keeps the two sources comparable.
static NSString *VTLabel(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        return ((UILabel *)view).text;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        return ((UIButton *)view).titleLabel.text;
    }
    return nil;
}

/// One node in the wire shape. `type` is deliberately absent — the host
/// normalizes class→type through the ONE shared map the lldb parser uses,
/// so the vocabulary can never drift between sources.
static NSDictionary *VTNode(UIView *view, NSInteger index, NSInteger parentIndex) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"index"] = @(index);
    if (parentIndex >= 0) node[@"parentIndex"] = @(parentIndex);
    node[@"viewClass"] = NSStringFromClass(object_getClass(view));
    NSString *base = VTBaseClass(view);
    if (base) node[@"baseClass"] = base;
    node[@"address"] = [NSString stringWithFormat:@"%p", view];
    CGRect frame = view.frame;
    node[@"rect"] = @{ @"x": @(frame.origin.x), @"y": @(frame.origin.y),
                       @"width": @(frame.size.width), @"height": @(frame.size.height) };
    if (view.hidden) node[@"hidden"] = @YES;
    if (view.alpha < 0.01) node[@"alpha0"] = @YES;
    if (view.clipsToBounds) node[@"clipped"] = @YES;
    NSString *label = VTLabel(view);
    if (label.length > 0) node[@"label"] = label;
    node[@"hittable"] = @(view.userInteractionEnabled);
    return node;
}

/// Walk `window.subviews` depth-first pre-order — the SAME order
/// recursiveDescription prints, so node sequences compare element-wise
/// between the two sources.
static NSArray *VTWalk(UIWindow *window) {
    NSMutableArray *nodes = [NSMutableArray array];
    __block NSInteger idx = 0;
    void (^recurse)(UIView *, NSInteger) = nil;
    recurse = ^(UIView *view, NSInteger parentIndex) {
        NSInteger self_ = idx++;
        [nodes addObject:VTNode(view, self_, parentIndex)];
        for (UIView *sub in view.subviews) {
            recurse(sub, self_);
        }
    };
    recurse(window, -1);
    return nodes;
}

/// Answer `id` with a dump (or an honest error payload), atomically.
static void VTRespond(NSString *id, NSString *bundleId, NSDictionary *extra) {
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"id"] = id;
    response[@"bundleId"] = bundleId;
    if (extra) [response addEntriesFromDictionary:extra];
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!json) {
        VTLog(@"[ViewTreeProbe] response serialization failed — writing an honest error");
        json = [NSJSONSerialization dataWithJSONObject:@{
            @"id": id, @"bundleId": bundleId, @"error": @"serialize" } options:0 error:nil];
        if (!json) return;
    }
    // Atomic, so a host polling concurrently never reads a half-written
    // dump — it either sees the previous response or this one.
    [json writeToFile:VTResponsePath() options:NSAtomicWrite error:nil];
}

/// The dump itself, on the main thread. Reads of UIKit state must happen
/// there; the walk of ~300 views is single-digit milliseconds.
static void VTPerformDump(NSString *id, NSString *bundleId) {
    UIWindow *window = VTKeyWindow();
    if (!window) {
        // Honest empty-of-target: same class as the lldb path's NO_APP.
        VTRespond(id, bundleId, @{ @"error": @"no-key-window" });
        return;
    }
    NSArray *nodes = VTWalk(window);
    VTRespond(id, bundleId, @{ @"nodes": nodes });
    VTLog(@"[ViewTreeProbe] dump answered (%lu nodes)", (unsigned long)nodes.count);
}

#pragma mark - Watcher

/// The stat-poll loop. Runs on a background queue; only the DUMP hops to
/// main. Generation-guarded against mtime/size reuse by the host writing
/// a new request with a fresh id — the id comparison is the contract.
static void VTInstallWatcher(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            NSDictionary *request = VTCurrentRequest();
            NSString *id = request[@"id"];
            if ([id isKindOfClass:[NSString class]] && id.length > 0) {
                NSString *answered;
                os_unfair_lock_lock(&gIdLock);
                answered = gAnsweredId;
                os_unfair_lock_unlock(&gIdLock);
                if (![id isEqualToString:answered]) {
                    os_unfair_lock_lock(&gIdLock);
                    gAnsweredId = [id copy];
                    os_unfair_lock_unlock(&gIdLock);
                    NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        VTPerformDump(id, bundleId);
                    });
                }
            }
            [NSThread sleepForTimeInterval:kPollInterval];
        }
    });
}
