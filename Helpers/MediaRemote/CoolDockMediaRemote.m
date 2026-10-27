// System-wide Now Playing for CoolDock.
//
// Since macOS 15.4 the MediaRemote daemon only answers Apple-signed clients, so CoolDock cannot ask it directly.
// This small library is loaded into /usr/bin/perl (an Apple platform binary) by mediaremote.pl and talks to
// MediaRemote from there. Protocol, one JSON object per line on stdout:
//   {"type":"ready"}                                   once, after notifications are registered
//   {"type":"info","title":…,"artist":…,"album":…,"duration":s,"elapsed":s,"timestamp":epoch,"rate":r,
//    "playing":bool,"pid":n,"bundle":id,"parent":id,"artworkID":hex,"artwork":base64?}
//                                                      on every change; artwork bytes only when artworkID changes
//   {"type":"none"}                                    nothing is playing
// Commands, one per line on stdin: play, pause, toggle, stop, next, previous, seek <seconds>, refresh.
// End of stdin (CoolDock quit or closed the pipe) exits the process.
//
// Build: clang -dynamiclib -fobjc-arc -O2 -framework Foundation -mmacosx-version-min=14.0 CoolDockMediaRemote.m

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetPlayingFn getPlaying;
static MRGetPIDFn getPID;
static MRGetClientFn getClient;
static MRClientStringFn clientBundle;
static MRClientStringFn clientParent;
static MRSendFn sendCommand;
static MRSetElapsedFn setElapsed;

static dispatch_queue_t queue;
static NSString *lastArtworkID;
static BOOL refreshPending;
static dispatch_source_t stdinSource;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// FNV-1a over the whole image so a new cover with the same size is still noticed.
static NSString *fingerprint(NSData *data) {
    uint64_t h = 0xcbf29ce484222325ULL;
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) { h ^= p[i]; h *= 0x100000001b3ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

static id stringOrEmpty(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static id numberOrZero(id value) { return [value isKindOfClass:NSNumber.class] ? value : @0; }

static void refresh(void) {
    getInfo(queue, ^(CFDictionaryRef ref) {
        NSDictionary *info = (__bridge NSDictionary *)ref;
        if (info.count == 0) {
            lastArtworkID = nil;
            emit(@{@"type": @"none"});
            return;
        }
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"type"] = @"info";
        out[@"title"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        out[@"artist"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        out[@"album"] = stringOrEmpty(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        out[@"duration"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        out[@"elapsed"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        out[@"rate"] = numberOrZero(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"timestamp"] = @([stamp isKindOfClass:NSDate.class] ? [(NSDate *)stamp timeIntervalSince1970] : NSDate.date.timeIntervalSince1970);

        id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:NSData.class] && [(NSData *)art length] > 0) {
            NSString *artID = fingerprint(art);
            out[@"artworkID"] = artID;
            if (![artID isEqualToString:lastArtworkID]) out[@"artwork"] = [(NSData *)art base64EncodedStringWithOptions:0];
            lastArtworkID = artID;
        } else {
            lastArtworkID = nil;
        }

        getPlaying(queue, ^(Boolean playing) {
            out[@"playing"] = playing ? @YES : @NO;
            getPID(queue, ^(int pid) {
                out[@"pid"] = @(pid);
                if (!getClient || !clientBundle) { emit(out); return; }
                getClient(queue, ^(id client) {
                    if (client) {
                        CFStringRef bundle = clientBundle(client);
                        if (bundle) out[@"bundle"] = (__bridge NSString *)bundle;
                        CFStringRef parent = clientParent ? clientParent(client) : NULL;
                        if (parent) out[@"parent"] = (__bridge NSString *)parent;
                    }
                    emit(out);
                });
            });
        });
    });
}

/// Coalesce bursts of notifications (a track change posts several) into one refresh.
static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
        if (refreshPending) return;
        refreshPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), queue, ^{
            refreshPending = NO;
            refresh();
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    // MRMediaRemoteCommand: play 0, pause 1, toggle 2, stop 3, next 4, previous 5.
    NSDictionary<NSString *, NSNumber *> *codes = @{@"play": @0, @"pause": @1, @"toggle": @2, @"stop": @3, @"next": @4, @"previous": @5};
    if (codes[cmd]) {
        sendCommand(codes[cmd].intValue, NULL);
    } else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) {
        setElapsed(parts[1].doubleValue);
    } else if ([cmd isEqualToString:@"refresh"]) {
        lastArtworkID = nil;
        scheduleRefresh();
    }
}

static void listenToStdin(void) {
    static NSMutableData *pending;
    pending = [NSMutableData data];
    stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(stdinSource, ^{
        char buffer[512];
        ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
        if (n <= 0) exit(0);  // CoolDock went away
        [pending appendBytes:buffer length:(NSUInteger)n];
        while (true) {
            NSRange nl = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)];
            if (nl.location == NSNotFound) break;
            NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, nl.location)] encoding:NSUTF8StringEncoding];
            [pending replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length) handleCommand(line);
        }
    });
    dispatch_resume(stdinSource);
}

/// Entry point, installed as a Perl XSUB by mediaremote.pl (Perl's arguments are ignored). Never returns.
void cdmr_stream(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "MediaRemote unavailable\n"); exit(2); }
    MRRegisterFn registerFn = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (MRGetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    getClient = (MRGetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = (MRSendFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!registerFn || !getInfo || !getPlaying || !getPID || !sendCommand) { fprintf(stderr, "MediaRemote symbols missing\n"); exit(3); }

    queue = dispatch_queue_create("app.cooldock.mediaremote", DISPATCH_QUEUE_SERIAL);
    registerFn(queue);
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }
    listenToStdin();
    emit(@{@"type": @"ready"});
    scheduleRefresh();
    CFRunLoopRun();
    exit(0);
}
