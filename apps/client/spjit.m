// The launcher's side of the on-device JIT helper (helper/, PlugIns/SPJitHelper.appex): before the client
// is loaded, it gets the helper attached to this process, so the libSystem shim's prepare stop
// (brk #0xf00d, shims/system/spsystem.c) is serviced with no Mac and no other app. A process can't service
// its own debugger stops, so the helper is a second process, an app extension the launcher starts.
//
// A launch is up to three requests, each a new helper process: status (the RemotePairing tunnel through
// LocalDevVPN at 10.7.0.1:49152, and whether the developer disk image is mounted), mount (when it isn't:
// debugserver is in it), then attach. The attach's reply only comes once the helper has detached, so the
// launcher waits for P_TRACED instead, and loads the client once the helper is attached. Before pairing
// and each status request, it waits for LocalDevVPN when that's off (spvpn.m), on a screen of its own.
//
// No public API starts an app's own classic extension, so this uses NSExtension's private class
// (ExtensionFoundation), the calls LiveContainer uses for LiveProcess: look the extension up by its bundle
// ID, begin a request with input items, and take the reply items in the completion block. Looking it up by
// bundle ID survives a sideloader renaming the app. research/jittest/helper_host.swift is the same in
// Swift, with the experiments' extras.
//
// What the helper is given, both in Library/: the RemotePairing record (sppairing.plist; a credential:
// handed over in memory, only its size is logged), and the disk image's files (spddi/, from the Mac's
// Xcode), read only when the device has no image mounted. The Mac companion puts both there, except the
// headset's record: the headset pairs with itself, on its first launch (sppair.m). A record the device no
// longer accepts (the helper's reply says "rejected") is deleted, so it's made again: on the headset right
// away, on an iPad or iPhone by the companion the next time it plays.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <sys/sysctl.h>

void sp_launch_say(NSString *s);  // launcher.m
void (^sp_launch_uikit(void))(double);  // launcher.m
NSData *sp_pair_headset(NSString *path, void (^pump)(double), NSString **problem);  // sppair.m
NSString *sp_vpn_wait(void (^*pump)(double), NSString *noun);  // spvpn.m
int sp_vpn_errno(void);  // spvpn.m

@interface NSObject (SPNSExtension)
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))completion;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *, NSArray *))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *, NSError *))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block;
@end

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

static void say(NSString *s) { sp_launch_say([@"jit: " stringByAppendingString:s]); }

int sp_traced(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && (kp.kp_proc.p_flag & P_TRACED);
}

// The person-facing name of this device, for the messages.
NSString *sp_device_noun(void) {  // also splogin.m and launcher.m
    switch (UIDevice.currentDevice.userInterfaceIdiom) {
        case UIUserInterfaceIdiomPhone: return @"iPhone";
        case UIUserInterfaceIdiomPad: return @"iPad";
        default: return @"Vision Pro";
    }
}

// The NSExtension objects, kept for their requests' lives: an NSExtension released mid-request drops it.
static NSMutableArray *live_extensions;

// One request: starts the helper (a new process) with `req` as the input item's userInfo, and calls `done`
// once with the reply item's userInfo, or nil (logged) when the helper didn't answer. The helper's log
// lines are logged first. `done` may run on any thread.
static void begin(NSDictionary *req, void (^done)(NSDictionary *reply)) {
    NSString *op = req[@"op"];
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"SPJitHelper.appex"];
    NSString *ident = [NSBundle bundleWithURL:url].bundleIdentifier;
    if (!ident) { say(@"no PlugIns/SPJitHelper.appex"); done(nil); return; }
    Class cls = NSClassFromString(@"NSExtension");
    if (!cls) {
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
        cls = NSClassFromString(@"NSExtension");
    }
    if (!cls) { say(@"no NSExtension class"); done(nil); return; }
    NSError *error = nil;
    id ext = [cls extensionWithIdentifier:ident error:&error];
    if (!ext) { say([NSString stringWithFormat:@"extensionWithIdentifier %@: %@", ident, error]); done(nil); return; }
    @synchronized (NSMutableArray.class) {
        if (!live_extensions) live_extensions = [NSMutableArray array];
        [live_extensions addObject:ext];
    }
    double t = now();
    __block BOOL fired = NO;
    NSObject *lock = [NSObject new];
    void (^finish)(NSDictionary *) = ^(NSDictionary *reply) {
        @synchronized (lock) {
            if (fired) return;
            fired = YES;
        }
        for (NSString *line in reply[@"log"]) say([@"helper: " stringByAppendingString:line]);
        done(reply);
    };
    [ext setRequestCompletionBlock:^(NSUUID *u, NSArray *items) {
        say([NSString stringWithFormat:@"%@ reply after %.3f s", op, now() - t]);
        NSExtensionItem *item = items.firstObject;
        finish([item isKindOfClass:NSExtensionItem.class] && item.userInfo ? (NSDictionary *)item.userInfo : @{});
    }];
    [ext setRequestCancellationBlock:^(NSUUID *u, NSError *e) {
        say([NSString stringWithFormat:@"%@ cancelled: %@", op, e ?: @"no error"]);
        finish(nil);
    }];
    [ext setRequestInterruptionBlock:^(NSUUID *u) {
        say([NSString stringWithFormat:@"%@ interrupted", op]);
        finish(nil);
    }];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = req;
    [ext beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *u) {
        if (!u) { say([NSString stringWithFormat:@"the %@ request didn't start", op]); finish(nil); return; }
        say([NSString stringWithFormat:@"started the helper for %@ as pid %d after %.3f s", op,
             [ext pidForRequestIdentifier:u], now() - t]);
    }];
}

// A request whose reply is waited for (up to `timeout` s), with `pump` keeping the main thread serving
// UIKit and the main queue meanwhile: the extension's blocks may be delivered there. sppair.m uses it too.
NSDictionary *sp_jit_request(NSDictionary *req, double timeout, void (^pump)(double)) {
    NSObject *lock = [NSObject new];
    __block NSDictionary *reply = nil;
    __block BOOL replied = NO;
    begin(req, ^(NSDictionary *r) {
        @synchronized (lock) {
            reply = r;
            replied = YES;
        }
    });
    for (double end = now() + timeout; now() < end;) {
        @synchronized (lock) {
            if (replied) return reply;
        }
        pump(0.01);
    }
    say([NSString stringWithFormat:@"no %@ reply after %.0f s", req[@"op"], timeout]);
    return nil;
}

// The disk image's files as the companion put them in Library/spddi/: files.txt lists their paths
// relative to spddi/Restore (as idevice loads them), version.txt names the Xcode they came from.
static NSDictionary *read_ddi(NSString *library) {
    NSString *dir = [library stringByAppendingPathComponent:@"spddi"];
    NSString *list = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"files.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    if (!list) { say(@"no developer disk image in Library/spddi"); return nil; }
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    unsigned long long bytes = 0;
    for (NSString *path in [list componentsSeparatedByString:@"\n"]) {
        if (!path.length) continue;
        NSData *data = [NSData dataWithContentsOfFile:[[dir stringByAppendingPathComponent:@"Restore"]
                                                          stringByAppendingPathComponent:path]
                                              options:NSDataReadingMappedIfSafe error:nil];
        if (!data) { say([@"developer disk image file missing: " stringByAppendingString:path]); return nil; }
        files[path] = data;
        bytes += data.length;
    }
    NSString *version = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"version.txt"]
                                                  encoding:NSUTF8StringEncoding error:nil];
    say([NSString stringWithFormat:@"developer disk image: %lu files, %llu bytes, %@", (unsigned long)files.count,
         bytes, [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"version unknown"]);
    return files;
}

static NSString *summary(NSDictionary *reply) { return reply[@"summary"] ?: @"no summary"; }

// Gets the helper attached to this process. Returns nil once it is (or when a debugger already is: one
// that launched the app, such as StikDebug, services the prepare itself), else what went wrong, for the
// person: the launcher shows it on the scene and doesn't load the client. `pump` runs the main thread
// for a while: UIKit, when it's up, and the main queue.
NSString *sp_jit_attach(void (^pump)(double)) {
    double t0 = now();
    NSString *noun = sp_device_noun();
    if (sp_traced()) {
        say(@"a debugger is already attached; it services the prepare");
        return nil;
    }
    // StikDebug's URL integration targets this running PID and uses the universal.js
    // breakpoint script. This path intentionally needs no Companion RemotePairing
    // record or developer disk image in this app: StikDebug manages its own.
    // Do not consider an opened URL to mean JIT succeeded.
#if !TARGET_OS_VISION
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"sp_use_stikdebug"]) {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (!bundle.length) return @"Slashplayed has no bundle ID for StikDebug.";
        NSURLComponents *components = [NSURLComponents new];
        components.scheme = @"stikdebug";
        components.host = @"enable-jit";
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundle],
            [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]],
            [NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]
        ];
        NSURL *url = components.URL;
        if (!url || ![UIApplication.sharedApplication canOpenURL:url])
            return @"StikDebug isn't installed or can't be opened. Install StikDebug, import its pairing file, enable LocalDevVPN, and try again.";
        __block BOOL opened = NO, answered = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
                opened = success;
                answered = YES;
            }];
        });
        double deadline = now() + 20;
        while (!answered && now() < deadline) pump(0.02);
        if (!opened) return @"iOS didn't open StikDebug for the JIT request.";
        say(@"StikDebug requested for running launcher; waiting for debugger attachment");
        // Opening StikDebug itself does not prove it attached. The game must not
        // dlopen before P_TRACED is true or the TXM brk will abort the process.
        deadline = now() + 120;
        while (!sp_traced() && now() < deadline) pump(0.02);
        if (!sp_traced())
            return @"StikDebug didn't attach to Slashplayed within two minutes. In StikDebug, enable JIT for Slashplayed with universal.js; confirm get-task-allow and LocalDevVPN are enabled.";
        say(@"StikDebug debugger attached; game can run the TXM prepare protocol");
        return nil;
    }
#endif
    NSString *library = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSString *record = [library stringByAppendingPathComponent:@"sppairing.plist"];
    NSData *pairing = [NSData dataWithContentsOfFile:record];
    // Empty is none: the companion's Pair Again empties it (devicectl can't delete files).
    if (pairing && !pairing.length) {
        say(@"empty pairing record (Pair Again): deleting it");
        [NSFileManager.defaultManager removeItemAtPath:record error:nil];
        pairing = nil;
    }
    NSArray *endpoints = @[@"10.7.0.1:49152"];
    NSDictionary *status = nil;
    NSString *problem = nil;
    // A rejected record is deleted, and on the headset made again, once.
    for (BOOL again = NO;;) {
        if (!pairing) {
            say(@"no pairing record (Library/sppairing.plist)");
#if TARGET_OS_VISION
            // LocalDevVPN first (spvpn.m): without it pair-setup could still reach the service by the
            // headset's own address, but the record's tunnel never comes up, and each try would leave the
            // person another paired host under Remote Devices.
            if ((problem = sp_vpn_wait(&pump, noun))) return problem;
            // The pairing screen waits on the person: UIKit has to be up for the launch watchdog.
            void (^ui)(double) = sp_launch_uikit();
            if (!ui) return @"Slashplayed needs to pair with this Vision Pro, but couldn't show its window.";
            pump = ui;
            pairing = sp_pair_headset(record, pump, &problem);
            if (!pairing) return problem;
#else
            return [NSString stringWithFormat:@"Slashplayed isn't paired with this %@ yet.\n\nOpen Slashplayed Companion on "
                    @"your Mac and play once with this %@ connected by USB: it pairs it.", noun, noun];
#endif
        }
        if ((problem = sp_vpn_wait(&pump, noun))) return problem;
        say([NSString stringWithFormat:@"pairing record: %lu bytes", (unsigned long)pairing.length]);
        status = sp_jit_request(@{@"op": @"status", @"pairing": pairing, @"endpoints": endpoints}, 30, pump);
        if (!status) {
            return @"Slashplayed's helper didn't start.\n\nInstall Slashplayed again from Slashplayed Companion on your Mac.";
        }
        say([@"status: " stringByAppendingString:summary(status)]);
        if ([status[@"ok"] boolValue]) break;
        if (![status[@"rejected"] boolValue]) {
            // LocalDevVPN turned off since the check: the loop waits for it again.
            if (sp_vpn_errno()) continue;
            return [NSString stringWithFormat:@"Slashplayed couldn't reach this %@'s developer services, though LocalDevVPN "
                    @"is on.\n\nIn LocalDevVPN, turn it off and on again, then close Slashplayed and open it again.\n\n(%@)",
                    noun, summary(status)];
        }
        if (again) {
            return [NSString stringWithFormat:@"This %@ didn't accept Slashplayed's new pairing either.\n\n(%@)",
                    noun, summary(status)];
        }
        again = YES;
        say(@"the device didn't accept the pairing record: deleting it");
        [NSFileManager.defaultManager removeItemAtPath:record error:nil];
        pairing = nil;
#if !TARGET_OS_VISION
        return [NSString stringWithFormat:@"This %@ no longer accepts Slashplayed's pairing.\n\nOpen Slashplayed Companion "
                @"on your Mac and play once with this %@ connected by USB: it pairs it again.", noun, noun];
#endif
    }
    if (![status[@"mounted"] boolValue]) {
        NSDictionary *ddi = read_ddi(library);
        if (!ddi) {
            return [NSString stringWithFormat:@"This %@ needs Apple's developer disk image, and Slashplayed doesn't have a "
                    @"copy yet.\n\nPlay once from Slashplayed Companion on your Mac: it copies the image to the %@.", noun, noun];
        }
        NSDictionary *mount = sp_jit_request(@{@"op": @"mount", @"pairing": pairing, @"endpoints": endpoints, @"ddi": ddi}, 120, pump);
        if (mount) say([@"mount: " stringByAppendingString:summary(mount)]);
        if (![mount[@"ok"] boolValue]) {
            return [NSString stringWithFormat:@"Mounting Apple's developer disk image failed. The %@ asks Apple's server "
                    @"for it, so it needs to be online.\n\n(%@)", noun, mount ? summary(mount) : @"no reply from the helper"];
        }
    }

    // The attach: its reply comes after the prepare, once the helper has detached, so what's waited for
    // here is P_TRACED (the helper attached) or an early reply (it couldn't).
    NSObject *lock = [NSObject new];
    __block NSDictionary *early = nil;
    __block BOOL replied = NO, attached = NO;
    double t = now();
    begin(@{@"op": @"attach", @"pid": @(getpid()), @"pairing": pairing, @"endpoints": endpoints}, ^(NSDictionary *r) {
        BOOL ok = [r[@"ok"] boolValue];
        // Logged here too: if the app dies before anything else is, this is the trace.
        say([NSString stringWithFormat:@"attach reply after %.2f s: %@%@", now() - t, ok ? @"" : @"FAIL: ",
             r ? summary(r) : @"no reply"]);
        @synchronized (lock) {
            if (!attached) early = r ?: @{};
            replied = YES;
        }
    });
    for (double end = now() + 30; now() < end;) {
        if (sp_traced()) {
            @synchronized (lock) {
                attached = YES;
            }
            say([NSString stringWithFormat:@"helper attached %.2f s after the launch started", now() - t0]);
            return nil;
        }
        @synchronized (lock) {
            if (replied) break;
        }
        pump(0.01);
    }
    return [NSString stringWithFormat:@"Slashplayed's helper couldn't attach to the game.\n\n(%@)",
            early ? summary(early) : @"it didn't attach within 30 s"];
}
