// simtouch — Native IndigoHID touch injection for iOS Simulator
//
// Uses SimulatorKit's IndigoHIDMessageForMouseNSEvent with inline ARM64 assembly
// to set SIMD registers, enabling direct screen-ratio input without mouse cursor.
//
// Build:
//   clang -o simtouch simtouch.m -framework Foundation -framework CoreGraphics \
//     -F/Library/Developer/PrivateFrameworks -framework CoreSimulator \
//     -rpath /Library/Developer/PrivateFrameworks \
//     -rpath /Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks \
//     -fno-objc-arc -O2
//
// Commands:
//   simtouch tap <x> <y> <screenW> <screenH> [--udid <udid>]
//   simtouch longpress <x> <y> <screenW> <screenH> <durationMs> [--udid <udid>]
//   simtouch swipe <x1> <y1> <x2> <y2> <screenW> <screenH> <durationMs> [steps] [--udid <udid>]
//   simtouch doubletap <x> <y> <screenW> <screenH> [intervalMs] [--udid <udid>]
//   simtouch multitap <x> <y> <screenW> <screenH> <count> [intervalMs] [--udid <udid>]
//
// Coordinates are in pixels. screenW/screenH are the device pixel dimensions.
// Outputs "ok" on success, error on stderr. Exit 0=success, 1=error.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>

typedef void* (*MouseMsgFn)(CGPoint *point0, void *point1, int target, int nsEventType, int direction);

static void err(const char *fmt, ...) {
    va_list args; va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args); fflush(stderr);
}

static id invokeClassMethod(Class cls, SEL sel, id arg1) {
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:cls]; [inv setSelector:sel];
    if (arg1) [inv setArgument:&arg1 atIndex:2];
    NSError *errOut = nil;
    [inv setArgument:&errOut atIndex:[sig numberOfArguments] - 1];
    [inv invoke];
    void *r = NULL; [inv getReturnValue:&r]; return (id)r;
}

static id invokeInstanceMethod(id t, SEL s, id a) {
    NSMethodSignature *sig = [t methodSignatureForSelector:s];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:t]; [inv setSelector:s];
    if (a) [inv setArgument:&a atIndex:2];
    NSError *e = nil;
    [inv setArgument:&e atIndex:[sig numberOfArguments] - 1];
    [inv invoke];
    void *r = NULL; [inv getReturnValue:&r]; return (id)r;
}

// Creates an IndigoHID message with correct SIMD register setup (ARM64).
// nsEventType: 1=leftMouseDown, 2=leftMouseUp, 6=leftMouseDragged
// direction: 1=down, 2=up, 0=drag
static void* createMessage(MouseMsgFn fn, double xRatio, double yRatio, int nsEventType, int direction) {
    CGPoint pt = CGPointMake(xRatio, yRatio);
    void *msg;
#if defined(__aarch64__)
    double one = 1.0;
    __asm__ volatile (
        "ldr d0, %[one]\n"
        "ldr d1, %[one]\n"
        "ldr d2, %[one]\n"
        "ldr d3, %[one]\n"
        : : [one] "m" (one)
        : "d0", "d1", "d2", "d3"
    );
    msg = fn(&pt, NULL, 0x32, nsEventType, direction);
#else
    // x86_64 fallback — pass point directly (not tested)
    msg = fn(&pt, NULL, 0x32, nsEventType, direction);
#endif
    return msg;
}

typedef struct {
    MouseMsgFn mouseFn;
    id client;
    SEL sendSel;
    NSMethodSignature *sendSig;
} SimContext;

static BOOL sendMessage(SimContext *ctx, void *msg) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_get_global_queue(0, 0);
    BOOL fwd = YES;
    __block BOOL ok = YES;
    void (^cb)(NSError *) = ^(NSError *e) {
        if (e) { err("send error: %s\n", [[e description] UTF8String]); ok = NO; }
        dispatch_semaphore_signal(sem);
    };
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:ctx->sendSig];
    [inv setTarget:ctx->client]; [inv setSelector:ctx->sendSel];
    [inv setArgument:&msg atIndex:2]; [inv setArgument:&fwd atIndex:3];
    [inv setArgument:&q atIndex:4]; [inv setArgument:&cb atIndex:5];
    [inv invoke];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
    return ok;
}

static SimContext* initContext(const char *targetUdid) {
    NSString *developerDir = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"LOCUS_DEVELOPER_DIR"] ?: @"/Applications/Xcode.app/Contents/Developer";
    NSString *simKitPath = [developerDir stringByAppendingPathComponent:
        @"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"];
    dlopen([simKitPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL);
    void *h = dlopen([simKitPath UTF8String], RTLD_NOW);
    if (!h) { err("Failed to load SimulatorKit\n"); return NULL; }

    MouseMsgFn fn = (MouseMsgFn)dlsym(h, "IndigoHIDMessageForMouseNSEvent");
    if (!fn) { err("IndigoHIDMessageForMouseNSEvent not found\n"); return NULL; }

    id ctx = invokeClassMethod(NSClassFromString(@"SimServiceContext"),
        @selector(sharedServiceContextForDeveloperDir:error:),
        developerDir);
    if (!ctx) { err("No SimServiceContext\n"); return NULL; }

    id dset = invokeInstanceMethod(ctx, @selector(defaultDeviceSetWithError:), nil);
    if (!dset) { err("No device set\n"); return NULL; }

    NSArray *devs = [dset performSelector:@selector(devices)];
    id bootedDev = nil;

    if (targetUdid) {
        NSString *udidStr = [NSString stringWithUTF8String:targetUdid];
        for (id d in devs) {
            NSString *devUdid = [[d valueForKey:@"UDID"] UUIDString];
            if ([devUdid caseInsensitiveCompare:udidStr] == NSOrderedSame &&
                [[d valueForKey:@"state"] integerValue] == 3) {
                bootedDev = d;
                break;
            }
        }
        if (!bootedDev) { err("Simulator %s not found or not booted\n", targetUdid); return NULL; }
    } else {
        for (id d in devs) {
            if ([[d valueForKey:@"state"] integerValue] == 3) { bootedDev = d; break; }
        }
        if (!bootedDev) { err("No booted simulator\n"); return NULL; }
    }

    Class cc = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (!cc) cc = objc_lookUpClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
    if (!cc) { err("SimDeviceLegacyHIDClient class not found\n"); return NULL; }

    id client = invokeInstanceMethod([cc alloc], @selector(initWithDevice:error:), bootedDev);
    if (!client) { err("Failed to create HID client\n"); return NULL; }

    SEL sendSel = @selector(sendWithMessage:freeWhenDone:completionQueue:completion:);
    NSMethodSignature *sendSig = [client methodSignatureForSelector:sendSel];
    if (!sendSig) { err("No sendWithMessage: signature\n"); return NULL; }

    SimContext *sc = calloc(1, sizeof(SimContext));
    sc->mouseFn = fn;
    sc->client = client;
    sc->sendSel = sendSel;
    sc->sendSig = sendSig;
    return sc;
}

static BOOL doTap(SimContext *ctx, double xRatio, double yRatio) {
    void *downMsg = createMessage(ctx->mouseFn, xRatio, yRatio, 1, 1);
    if (!downMsg) { err("Failed to create down message\n"); return NO; }
    if (!sendMessage(ctx, downMsg)) return NO;
    usleep(170000); // 170ms hold — beyond UIScrollView's delaysContentTouches threshold
    void *upMsg = createMessage(ctx->mouseFn, xRatio, yRatio, 2, 2);
    if (!upMsg) { err("Failed to create up message\n"); return NO; }
    return sendMessage(ctx, upMsg);
}

static BOOL doLongPress(SimContext *ctx, double xRatio, double yRatio, int durationMs) {
    void *downMsg = createMessage(ctx->mouseFn, xRatio, yRatio, 1, 1);
    if (!downMsg) { err("Failed to create down message\n"); return NO; }
    if (!sendMessage(ctx, downMsg)) return NO;
    usleep(durationMs * 1000);
    void *upMsg = createMessage(ctx->mouseFn, xRatio, yRatio, 2, 2);
    if (!upMsg) { err("Failed to create up message\n"); return NO; }
    return sendMessage(ctx, upMsg);
}

static BOOL doSwipe(SimContext *ctx, double x1r, double y1r,
                    double x2r, double y2r, int durationMs, int steps) {
    void *downMsg = createMessage(ctx->mouseFn, x1r, y1r, 1, 1);
    if (!downMsg) { err("Failed to create down message\n"); return NO; }
    if (!sendMessage(ctx, downMsg)) return NO;
    usleep(20000); // 20ms initial hold

    int stepDelay = (durationMs * 1000) / steps;
    for (int i = 1; i <= steps; i++) {
        double f = (double)i / steps;
        double xr = x1r + (x2r - x1r) * f;
        double yr = y1r + (y2r - y1r) * f;
        void *dragMsg = createMessage(ctx->mouseFn, xr, yr, 6, 0);
        if (dragMsg) sendMessage(ctx, dragMsg);
        usleep(stepDelay);
    }

    void *upMsg = createMessage(ctx->mouseFn, x2r, y2r, 2, 2);
    if (!upMsg) { err("Failed to create up message\n"); return NO; }
    return sendMessage(ctx, upMsg);
}

static BOOL doDoubleTap(SimContext *ctx, double xRatio, double yRatio, int intervalMs) {
    if (!doTap(ctx, xRatio, yRatio)) return NO;
    usleep(intervalMs * 1000);
    return doTap(ctx, xRatio, yRatio);
}

static BOOL doMultiTap(SimContext *ctx, double xRatio, double yRatio, int count, int intervalMs) {
    for (int i = 0; i < count; i++) {
        if (!doTap(ctx, xRatio, yRatio)) return NO;
        if (i < count - 1) usleep(intervalMs * 1000);
    }
    return YES;
}

// Parse --udid from remaining argv
static const char* findUdid(int argc, const char *argv[]) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "--udid") == 0) return argv[i + 1];
    }
    return NULL;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            err("Usage:\n");
            err("  simtouch tap <x> <y> <screenW> <screenH> [--udid <udid>]\n");
            err("  simtouch longpress <x> <y> <screenW> <screenH> <durationMs> [--udid <udid>]\n");
            err("  simtouch swipe <x1> <y1> <x2> <y2> <screenW> <screenH> <durationMs> [steps] [--udid <udid>]\n");
            err("  simtouch doubletap <x> <y> <screenW> <screenH> [intervalMs] [--udid <udid>]\n");
            err("  simtouch multitap <x> <y> <screenW> <screenH> <count> [intervalMs] [--udid <udid>]\n");
            return 1;
        }

        const char *cmd = argv[1];
        const char *udid = findUdid(argc, argv);
        SimContext *ctx = initContext(udid);
        if (!ctx) return 1;

        if (strcmp(cmd, "tap") == 0) {
            if (argc < 6) { err("tap requires: x y screenW screenH\n"); return 1; }
            double x = atof(argv[2]), y = atof(argv[3]);
            double w = atof(argv[4]), h = atof(argv[5]);
            if (w <= 0 || h <= 0) { err("Invalid screen dimensions\n"); return 1; }
            if (!doTap(ctx, x / w, y / h)) return 1;
        }
        else if (strcmp(cmd, "longpress") == 0) {
            if (argc < 7) { err("longpress requires: x y screenW screenH durationMs\n"); return 1; }
            double x = atof(argv[2]), y = atof(argv[3]);
            double w = atof(argv[4]), h = atof(argv[5]);
            int dur = atoi(argv[6]);
            if (w <= 0 || h <= 0) { err("Invalid screen dimensions\n"); return 1; }
            if (dur < 100) dur = 100;
            if (!doLongPress(ctx, x / w, y / h, dur)) return 1;
        }
        else if (strcmp(cmd, "swipe") == 0) {
            if (argc < 9) { err("swipe requires: x1 y1 x2 y2 screenW screenH durationMs [steps]\n"); return 1; }
            double x1 = atof(argv[2]), y1 = atof(argv[3]);
            double x2 = atof(argv[4]), y2 = atof(argv[5]);
            double w = atof(argv[6]), h = atof(argv[7]);
            int dur = atoi(argv[8]);
            int steps = 25;
            // Check if next arg is steps (not --udid)
            if (argc > 9 && strcmp(argv[9], "--udid") != 0) steps = atoi(argv[9]);
            if (w <= 0 || h <= 0) { err("Invalid screen dimensions\n"); return 1; }
            if (dur < 50) dur = 50;
            if (steps < 2) steps = 2;
            if (!doSwipe(ctx, x1/w, y1/h, x2/w, y2/h, dur, steps)) return 1;
        }
        else if (strcmp(cmd, "doubletap") == 0) {
            if (argc < 6) { err("doubletap requires: x y screenW screenH [intervalMs]\n"); return 1; }
            double x = atof(argv[2]), y = atof(argv[3]);
            double w = atof(argv[4]), h = atof(argv[5]);
            int interval = 100;
            if (argc > 6 && strcmp(argv[6], "--udid") != 0) interval = atoi(argv[6]);
            if (w <= 0 || h <= 0) { err("Invalid screen dimensions\n"); return 1; }
            if (!doDoubleTap(ctx, x / w, y / h, interval)) return 1;
        }
        else if (strcmp(cmd, "multitap") == 0) {
            if (argc < 7) { err("multitap requires: x y screenW screenH count [intervalMs]\n"); return 1; }
            double x = atof(argv[2]), y = atof(argv[3]);
            double w = atof(argv[4]), h = atof(argv[5]);
            int count = atoi(argv[6]);
            int interval = 100;
            if (argc > 7 && strcmp(argv[7], "--udid") != 0) interval = atoi(argv[7]);
            if (w <= 0 || h <= 0) { err("Invalid screen dimensions\n"); return 1; }
            if (count < 1) count = 1;
            if (!doMultiTap(ctx, x / w, y / h, count, interval)) return 1;
        }
        else {
            err("Unknown command: %s\n", cmd);
            return 1;
        }

        usleep(50000); // Brief settle time
        printf("ok\n");
    }
    return 0;
}
