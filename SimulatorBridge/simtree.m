// simtree — iOS Simulator accessibility tree dumper
//
// Uses AccessibilityPlatformTranslation private framework with SimDevice's
// sendAccessibilityRequestAsync to get the accessibility tree from a running
// iOS simulator app, WITHOUT requiring macOS accessibility permissions and
// WITHOUT installing anything in the simulator.
//
// Build:
//   clang -o simtree simtree.m -framework Foundation -framework CoreGraphics \
//     -F/Library/Developer/PrivateFrameworks \
//     -framework CoreSimulator \
//     -rpath /Library/Developer/PrivateFrameworks \
//     -rpath /Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks \
//     -fobjc-arc -O2
//
// Note: ARC (-fobjc-arc) is required. The bridge callback block must retain
// the AXPTranslatorResponse return value across the synchronous wait; without
// ARC the response gets over-released and crashes inside sendTranslatorRequest:.
//
// Usage:
//   simtree [--udid <udid>]
//
// Output: JSON array of accessibility elements on stdout.
// Errors go to stderr. Exit 0=success, 1=error.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// Logging helper
// ---------------------------------------------------------------------------
static void err(const char *fmt, ...) {
    va_list args; va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args); fflush(stderr);
}

// ---------------------------------------------------------------------------
// Bridge delegate protocol
// ---------------------------------------------------------------------------
@protocol AXPTranslationTokenDelegateHelper <NSObject>
@required
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token;
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token;
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token;
@end

// ---------------------------------------------------------------------------
// Bridge delegate — implements AXPTranslationTokenDelegateHelper.
// Bridges the async SimDevice XPC call into the synchronous block that
// AXPTranslator expects.
// ---------------------------------------------------------------------------
@interface AXPBridgeDelegate : NSObject <AXPTranslationTokenDelegateHelper>
@property (nonatomic, strong) id simDevice;
@end

@implementation AXPBridgeDelegate

- (instancetype)initWithDevice:(id)device {
    self = [super init];
    if (self) { _simDevice = device; }
    return self;
}

// Returns a block: AXPTranslatorResponse *(^)(AXPTranslatorRequest *)
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    id device = self.simDevice;
    // Use a concurrent global queue so the completion handler never deadlocks
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    id block = ^id(id axRequest) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block id response = nil;

        SEL sel = @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:);
        NSMethodSignature *sig = [device methodSignatureForSelector:sel];
        if (!sig) { return nil; }

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:device];
        [inv setSelector:sel];
        // Use intermediate variables for NSInvocation argument passing with ARC
        id __autoreleasing axReq = axRequest;
        [inv setArgument:&axReq atIndex:2];
        dispatch_queue_t q = queue;
        [inv setArgument:&q atIndex:3];
        void (^handler)(id) = ^(id r) {
            response = r;
            dispatch_semaphore_signal(sem);
        };
        [inv setArgument:&handler atIndex:4];
        [inv invoke];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
        return response;
    };

    return [block copy];
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
    return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
    return nil;
}

@end

// ---------------------------------------------------------------------------
// NSInvocation helpers — use ARC-safe bridge casts
// ---------------------------------------------------------------------------
static id invokeCls(Class cls, SEL sel, id arg1) {
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:cls]; [inv setSelector:sel];
    if (arg1) {
        id tmp = arg1;
        [inv setArgument:&tmp atIndex:2];
    }
    NSError *e = nil;
    NSUInteger last = [sig numberOfArguments] - 1;
    [inv setArgument:&e atIndex:last];
    [inv invoke];
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge id)r;
}

static id invokeInst(id t, SEL s, id a) {
    NSMethodSignature *sig = [t methodSignatureForSelector:s];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:t]; [inv setSelector:s];
    if (a) {
        id tmp = a;
        [inv setArgument:&tmp atIndex:2];
    }
    NSError *e = nil;
    NSUInteger last = [sig numberOfArguments] - 1;
    [inv setArgument:&e atIndex:last];
    [inv invoke];
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge id)r;
}

// Generic invoke returning id
static id invokeId(id target, SEL sel) {
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target]; [inv setSelector:sel];
    @try { [inv invoke]; } @catch (...) { return nil; }
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge id)r;
}

// Invoke with one id argument
static id invokeIdArg(id target, SEL sel, id arg) {
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target]; [inv setSelector:sel];
    id tmp = arg;
    [inv setArgument:&tmp atIndex:2];
    @try { [inv invoke]; } @catch (...) { return nil; }
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge id)r;
}

// ---------------------------------------------------------------------------
// Device finding (same pattern as simtouch.m)
// ---------------------------------------------------------------------------
static id findBootedDevice(const char *targetUdid) {
    NSString *developerDir = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"LOCUS_DEVELOPER_DIR"] ?: @"/Applications/Xcode.app/Contents/Developer";
    id ctx = invokeCls(NSClassFromString(@"SimServiceContext"),
        @selector(sharedServiceContextForDeveloperDir:error:),
        developerDir);
    if (!ctx) { err("No SimServiceContext\n"); return nil; }

    id dset = invokeInst(ctx, @selector(defaultDeviceSetWithError:), nil);
    if (!dset) { err("No device set\n"); return nil; }

    NSArray *devs = [dset performSelector:@selector(devices)];

    if (targetUdid) {
        NSString *udidStr = [NSString stringWithUTF8String:targetUdid];
        for (id d in devs) {
            NSString *devUdid = [[d valueForKey:@"UDID"] UUIDString];
            if ([devUdid caseInsensitiveCompare:udidStr] == NSOrderedSame &&
                [[d valueForKey:@"state"] integerValue] == 3) {
                return d;
            }
        }
        err("Simulator %s not found or not booted\n", targetUdid);
        return nil;
    }

    for (id d in devs) {
        if ([[d valueForKey:@"state"] integerValue] == 3) return d;
    }
    err("No booted simulator\n");
    return nil;
}

// ---------------------------------------------------------------------------
// JSON string escaping
// ---------------------------------------------------------------------------
static NSString *jsonEscape(NSString *s) {
    if (!s) return @"";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0, len = s.length; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", (unsigned)c];
                else          [out appendFormat:@"%C", c];
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Accessor helpers — NSInvocation-based to avoid compile-time method warnings
// ---------------------------------------------------------------------------
static id axAttrValue(id elem, NSString *attr) {
    SEL sel = @selector(accessibilityAttributeValue:);
    if (![elem respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [elem methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:elem]; [inv setSelector:sel];
    [inv setArgument:&attr atIndex:2];
    @try { [inv invoke]; } @catch (...) { return nil; }
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge id)r;
}

static CGRect axFrame(id elem) {
    SEL frameSel = @selector(accessibilityFrame);
    if ([elem respondsToSelector:frameSel]) {
        NSMethodSignature *sig = [elem methodSignatureForSelector:frameSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:elem]; [inv setSelector:frameSel];
            @try { [inv invoke]; } @catch (...) { goto fallback; }
            CGRect r; [inv getReturnValue:&r]; return r;
        }
    }
fallback:;
    id val = axAttrValue(elem, @"AXFrame");
    if (val && [val isKindOfClass:[NSValue class]]) {
        CGRect r; [(NSValue *)val getValue:&r]; return r;
    }
    return CGRectZero;
}

static NSArray *axChildren(id elem) {
    SEL childSel = @selector(accessibilityChildren);
    if ([elem respondsToSelector:childSel]) {
        NSMethodSignature *sig = [elem methodSignatureForSelector:childSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:elem]; [inv setSelector:childSel];
            @try { [inv invoke]; } @catch (...) { goto fallback2; }
            void *r = NULL;
            [inv getReturnValue:&r];
            NSArray *ch = (__bridge NSArray *)r;
            if (ch) return ch;
        }
    }
fallback2:;
    id v = axAttrValue(elem, @"AXChildren");
    if ([v isKindOfClass:[NSArray class]]) return v;
    return nil;
}

static BOOL axIsIgnored(id elem) {
    SEL sel = @selector(accessibilityIsIgnored);
    if (![elem respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [elem methodSignatureForSelector:sel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:elem]; [inv setSelector:sel];
    @try { [inv invoke]; } @catch (...) { return NO; }
    BOOL r = NO; [inv getReturnValue:&r]; return r;
}

static NSString *axLabel(id elem) {
    SEL sel = @selector(accessibilityLabel);
    if (![elem respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [elem methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:elem]; [inv setSelector:sel];
    @try { [inv invoke]; } @catch (...) { return nil; }
    void *r = NULL;
    [inv getReturnValue:&r];
    return (__bridge NSString *)r;
}

// ---------------------------------------------------------------------------
// Tree walking
// ---------------------------------------------------------------------------
static NSMutableArray *gElements = nil;
static int gIndex = 0;

static void walkElement(id elem, int depth) {
    if (!elem) return;
    if (depth > 60) return;

    {
        NSString *role       = nil;
        NSString *label      = nil;
        NSString *identifier = nil;
        NSString *value      = nil;
        NSString *hint       = nil;
        BOOL enabled         = YES;
        BOOL focused         = NO;
        BOOL selected        = NO;

        id roleVal = axAttrValue(elem, @"AXRole");
        if ([roleVal isKindOfClass:[NSString class]]) role = roleVal;

        label = axLabel(elem);
        if (!label) {
            id lv = axAttrValue(elem, @"AXLabel");
            if ([lv isKindOfClass:[NSString class]]) label = lv;
        }
        if (!label) {
            id dv = axAttrValue(elem, @"AXDescription");
            if ([dv isKindOfClass:[NSString class]]) label = dv;
        }

        id idVal = axAttrValue(elem, @"AXIdentifier");
        if ([idVal isKindOfClass:[NSString class]]) identifier = idVal;

        id valVal = axAttrValue(elem, @"AXValue");
        if (valVal) {
            if ([valVal isKindOfClass:[NSString class]]) value = valVal;
            else value = [valVal description];
        }

        id hintVal = axAttrValue(elem, @"AXHelp");
        if ([hintVal isKindOfClass:[NSString class]]) hint = hintVal;

        id enVal = axAttrValue(elem, @"AXEnabled");
        if ([enVal isKindOfClass:[NSNumber class]]) enabled = [enVal boolValue];

        id foVal = axAttrValue(elem, @"AXFocused");
        if ([foVal isKindOfClass:[NSNumber class]]) focused = [foVal boolValue];

        id seVal = axAttrValue(elem, @"AXSelected");
        if ([seVal isKindOfClass:[NSNumber class]]) selected = [seVal boolValue];

        CGRect frame = axFrame(elem);
        double cx = frame.origin.x + frame.size.width  / 2.0;
        double cy = frame.origin.y + frame.size.height / 2.0;

        [gElements addObject:@{
            @"index":       @(gIndex++),
            @"elementType": role       ?: @"",
            @"identifier":  identifier ?: @"",
            @"label":       label      ?: @"",
            @"value":       value      ?: @"",
            @"hint":        hint       ?: @"",
            @"bounds": @{
                @"x":      @(frame.origin.x),
                @"y":      @(frame.origin.y),
                @"width":  @(frame.size.width),
                @"height": @(frame.size.height)
            },
            @"center": @{ @"x": @(cx), @"y": @(cy) },
            @"enabled":  @(enabled),
            @"focused":  @(focused),
            @"selected": @(selected)
        }];
    }

    NSArray *children = axChildren(elem);
    for (id child in children) {
        walkElement(child, depth + 1);
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------
static NSString *elemToJSON(NSDictionary *e) {
    NSDictionary *b = e[@"bounds"];
    NSDictionary *c = e[@"center"];
    return [NSString stringWithFormat:
        @"{\"index\":%@,\"elementType\":\"%@\",\"identifier\":\"%@\","
         "\"label\":\"%@\",\"value\":\"%@\",\"hint\":\"%@\","
         "\"bounds\":{\"x\":%@,\"y\":%@,\"width\":%@,\"height\":%@},"
         "\"center\":{\"x\":%@,\"y\":%@},"
         "\"enabled\":%@,\"focused\":%@,\"selected\":%@}",
        e[@"index"],
        jsonEscape(e[@"elementType"]),
        jsonEscape(e[@"identifier"]),
        jsonEscape(e[@"label"]),
        jsonEscape(e[@"value"]),
        jsonEscape(e[@"hint"]),
        b[@"x"], b[@"y"], b[@"width"], b[@"height"],
        c[@"x"], c[@"y"],
        [e[@"enabled"]  boolValue] ? @"true"  : @"false",
        [e[@"focused"]  boolValue] ? @"true"  : @"false",
        [e[@"selected"] boolValue] ? @"true" : @"false"
    ];
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Parse --udid
        const char *udid = NULL;
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--udid") == 0) { udid = argv[i + 1]; break; }
        }

        // Load private frameworks
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
               RTLD_NOW | RTLD_GLOBAL);
        if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/"
                    "AccessibilityPlatformTranslation", RTLD_NOW | RTLD_GLOBAL)) {
            err("Failed to load AccessibilityPlatformTranslation: %s\n", dlerror());
            return 1;
        }

        // Find booted device
        id device = findBootedDevice(udid);
        if (!device) return 1;
        err("Found device: %s\n", [[[device valueForKey:@"name"] description] UTF8String]);

        // Get AXPTranslator singleton
        Class translatorClass = NSClassFromString(@"AXPTranslator");
        if (!translatorClass) { err("AXPTranslator class not found\n"); return 1; }
        id translator = [translatorClass performSelector:@selector(sharedInstance)];
        if (!translator) { err("AXPTranslator sharedInstance returned nil\n"); return 1; }

        // Enable accessibility
        {
            SEL enSel = @selector(setAccessibilityEnabled:);
            NSMethodSignature *sig = [translator methodSignatureForSelector:enSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:translator]; [inv setSelector:enSel];
                BOOL yes = YES; [inv setArgument:&yes atIndex:2];
                [inv invoke];
            }
        }

        // Create bridge delegate (strong reference so weak bridgeTokenDelegate stays alive)
        AXPBridgeDelegate *bridgeDelegate = [[AXPBridgeDelegate alloc] initWithDevice:device];
        {
            SEL bdSel = @selector(setBridgeTokenDelegate:);
            NSMethodSignature *sig = [translator methodSignatureForSelector:bdSel];
            if (!sig) { err("Translator has no setBridgeTokenDelegate:\n"); return 1; }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:translator]; [inv setSelector:bdSel];
            id bd = bridgeDelegate;
            [inv setArgument:&bd atIndex:2];
            [inv invoke];
        }

        // Fresh UUID token (per idb implementation pattern)
        NSString *token = [NSUUID UUID].UUIDString;
        err("Using token: %s\n", [token UTF8String]);

        // Run the AXP work on a serial background queue.
        // The main thread spins a runloop so XPC replies can be received.
        __block int exitCode = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_queue_t workQ = dispatch_queue_create("com.simtree.work", DISPATCH_QUEUE_SERIAL);

        dispatch_async(workQ, ^{
            @autoreleasepool {
                // Get frontmost application translation object
                err("Calling frontmostApplicationWithDisplayId:bridgeDelegateToken:...\n");
                SEL faSel = @selector(frontmostApplicationWithDisplayId:bridgeDelegateToken:);
                NSMethodSignature *sig = [translator methodSignatureForSelector:faSel];
                if (!sig) {
                    err("No frontmostApplicationWithDisplayId:bridgeDelegateToken:\n");
                    exitCode = 1; dispatch_semaphore_signal(done); return;
                }
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:translator]; [inv setSelector:faSel];
                NSInteger displayId = 0;
                [inv setArgument:&displayId atIndex:2];
                NSString *tok = token;
                [inv setArgument:&tok atIndex:3];
                [inv invoke];
                void *tr = NULL;
                [inv getReturnValue:&tr];
                id translationObject = (__bridge id)tr;

                if (!translationObject) {
                    err("frontmostApplicationWithDisplayId returned nil — is the app in foreground?\n");
                    exitCode = 1; dispatch_semaphore_signal(done); return;
                }
                err("Translation object: %s\n", [[translationObject description] UTF8String]);

                // Get AXPMacPlatformElement from translation object
                id rootElement = invokeIdArg(translator,
                    @selector(macPlatformElementFromTranslation:), translationObject);

                if (!rootElement) {
                    err("macPlatformElementFromTranslation returned nil\n");
                    exitCode = 1; dispatch_semaphore_signal(done); return;
                }
                err("Root element class: %s\n", [NSStringFromClass([rootElement class]) UTF8String]);

                // Walk the accessibility tree
                gElements = [NSMutableArray array];
                gIndex = 0;
                walkElement(rootElement, 0);
                err("Found %lu elements\n", (unsigned long)gElements.count);

                // Emit JSON
                NSMutableString *json = [NSMutableString string];
                [json appendString:@"["];
                for (NSUInteger i = 0; i < gElements.count; i++) {
                    if (i > 0) [json appendString:@","];
                    [json appendString:elemToJSON(gElements[i])];
                }
                [json appendString:@"]"];
                printf("%s\n", [json UTF8String]);

                dispatch_semaphore_signal(done);
            }
        });

        // Spin the main runloop while waiting (needed for XPC replies)
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        return exitCode;
    }
}
