#import "Diagnostics.h"
#import "ZTweakLog.h"
#import "Version.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <time.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <sys/utsname.h>

#pragma mark - ZCrashLogger

static int g_crashLogFD = -1;
static int g_pendingFD = -1;
static NSString *g_crashLogPath = nil;
static NSString *g_currentReportPath = nil;
static NSString *g_pendingReportPath = nil;
static char g_reportHeader[1024];

static const int kHandledSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
static const int kHandledSignalCount = sizeof(kHandledSignals) / sizeof(kHandledSignals[0]);

static uint8_t g_altStack[64 * 1024];

static struct sigaction g_previousActions[NSIG];
static NSUncaughtExceptionHandler *g_previousExceptionHandler = NULL;
static volatile int g_handling = 0;
static dispatch_source_t g_reinstallTimer = nil;

#pragma mark - Async-signal-safe helpers

static void safe_write(const char *s, size_t length) {
    if (!s || length == 0) return;
    if (g_crashLogFD >= 0) write(g_crashLogFD, s, length);
    if (g_pendingFD >= 0) write(g_pendingFD, s, length);
}

static void safe_write_str(const char *s) {
    if (s) safe_write(s, strlen(s));
}

static void safe_write_hex(uintptr_t value) {
    char buf[2 + sizeof(uintptr_t) * 2 + 1];
    char *p = buf + sizeof(buf) - 1;
    *p = '\0';
    if (value == 0) {
        *--p = '0';
    } else {
        while (value != 0) {
            uint8_t nibble = value & 0xF;
            *--p = (nibble < 10) ? ('0' + nibble) : ('a' + (nibble - 10));
            value >>= 4;
        }
    }
    *--p = 'x';
    *--p = '0';
    safe_write_str(p);
}

static void safe_write_dec(unsigned long long value) {
    char buf[24];
    char *p = buf + sizeof(buf) - 1;
    *p = '\0';
    if (value == 0) {
        *--p = '0';
    } else {
        while (value != 0) {
            *--p = (char)('0' + (value % 10));
            value /= 10;
        }
    }
    safe_write_str(p);
}

static void safe_sync(void) {
    if (g_crashLogFD >= 0) fsync(g_crashLogFD);
    if (g_pendingFD >= 0) fsync(g_pendingFD);
}

static const char *name_for_signal(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        case SIGKILL: return "SIGKILL";
        default:      return "UNKNOWN";
    }
}

static void write_crash_report(int sig, void *faultAddress, int hasFaultAddress) {
    safe_write_str("\n=== ZCrashLogger: fatal signal ===\n");
    safe_write_str(g_reportHeader);
    safe_write_str("time: ");
    safe_write_dec((unsigned long long)time(NULL));
    safe_write_str("\nsignal: ");
    safe_write_str(name_for_signal(sig));
    safe_write_str("\n");

    if (hasFaultAddress) {
        safe_write_str("si_addr (faulting address, SIGSEGV/SIGBUS only - meaningless for other signals): ");
        safe_write_hex((uintptr_t)faultAddress);
        safe_write_str("\n");
    }

    safe_write_str("backtrace:\n");

    void *frames[64];
    int frameCount = backtrace(frames, 64);
    if (frameCount > 0) {
        if (g_crashLogFD >= 0) backtrace_symbols_fd(frames, frameCount, g_crashLogFD);
        if (g_pendingFD >= 0) backtrace_symbols_fd(frames, frameCount, g_pendingFD);
    } else {
        safe_write_str("(backtrace() returned no frames)\n");
    }

    safe_write_str("=== end ===\n");
    safe_sync();
}

static void crash_signal_handler(int sig, siginfo_t *info, void *uctx) {
    if (__sync_lock_test_and_set(&g_handling, 1)) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    write_crash_report(sig, info ? info->si_addr : NULL, info != NULL);

    struct sigaction previous;
    memset(&previous, 0, sizeof(previous));
    if (sig > 0 && sig < NSIG) previous = g_previousActions[sig];

    if (previous.sa_flags & SA_SIGINFO) {
        if (previous.sa_sigaction && previous.sa_sigaction != crash_signal_handler) {
            previous.sa_sigaction(sig, info, uctx);
        }
    } else if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN && previous.sa_handler != NULL) {
        previous.sa_handler(sig);
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

#pragma mark - Uncaught NSException handler

static void uncaught_exception_handler(NSException *exception) {
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"\n=== ZCrashLogger: uncaught NSException ===\n%s" "time: %lld\nname: %@\nreason: %@\ncallStackSymbols:\n%@\n=== end ===\n",
        g_reportHeader, (long long)time(NULL),
        exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    const char *utf8 = log.UTF8String;
    if (utf8) {
        safe_write(utf8, strlen(utf8));
        safe_sync();
    }
    ZLog(@"%@", log);

    if (g_previousExceptionHandler && g_previousExceptionHandler != &uncaught_exception_handler) {
        g_previousExceptionHandler(exception);
    }
}

#pragma mark - std::terminate capture (uncaught NSException, handler-independent)

extern void __cxa_rethrow(void) __attribute__((noreturn));

static void (*g_previousTerminate)(void) = NULL;
static volatile int g_terminateHandling = 0;

static void zs_terminate_handler(void) {
    if (__sync_lock_test_and_set(&g_terminateHandling, 1)) {
        abort();
    }
    @try {
        __cxa_rethrow();
    } @catch (NSException *exception) {
        NSString *log = [NSString stringWithFormat:
            @"\n=== ZCrashLogger: uncaught NSException ===\n%s" "time: %lld\nname: %@\nreason: %@\ncallStackSymbols:\n%@\n=== end ===\n",
            g_reportHeader, (long long)time(NULL),
            exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
        const char *utf8 = log.UTF8String;
        if (utf8) {
            safe_write(utf8, strlen(utf8));
            safe_sync();
        }
    }
    // The exception object is gone after the catch; nothing left for the
    // previous handler to inspect, so finish the abort here (the SIGABRT
    // handler still writes its own backtrace section).
    abort();
}

static void zs_install_terminate_handler(void) {
    typedef void (*terminate_fn)(void);
    typedef terminate_fn (*set_terminate_fn)(terminate_fn);
    typedef terminate_fn (*get_terminate_fn)(void);
    static set_terminate_fn setter;
    static get_terminate_fn getter;
    if (!setter) {
        setter = (set_terminate_fn)dlsym(RTLD_DEFAULT, "_ZSt13set_terminatePFvvE");
        getter = (get_terminate_fn)dlsym(RTLD_DEFAULT, "_ZSt13get_terminatev");
    }
    if (!setter) return;
    if (getter && getter() == zs_terminate_handler) return;
    terminate_fn previous = setter(zs_terminate_handler);
    if (previous != zs_terminate_handler) g_previousTerminate = previous;
}

static void install_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = crash_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;

    for (int i = 0; i < kHandledSignalCount; i++) {
        int sig = kHandledSignals[i];
        struct sigaction current;
        memset(&current, 0, sizeof(current));
        if (sigaction(sig, NULL, &current) != 0) continue;
        if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == crash_signal_handler) continue;
        g_previousActions[sig] = current;
        sigaction(sig, &action, NULL);
    }

    zs_install_terminate_handler();

    NSUncaughtExceptionHandler *currentExceptionHandler = NSGetUncaughtExceptionHandler();
    if (currentExceptionHandler != &uncaught_exception_handler) {
        g_previousExceptionHandler = currentExceptionHandler;
        NSSetUncaughtExceptionHandler(&uncaught_exception_handler);
    }
}

static NSString *zs_documents_path(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

@implementation ZCrashLogger

+ (NSString *)crashLogPath {
    if (!g_crashLogPath) {
        g_crashLogPath = [zs_documents_path() stringByAppendingPathComponent:@"zsingularity_crash.log"];
    }
    return g_crashLogPath;
}

+ (NSString *)currentReportPath {
    if (!g_currentReportPath) {
        g_currentReportPath = [zs_documents_path() stringByAppendingPathComponent:@"zsingularity_crash_current.log"];
    }
    return g_currentReportPath;
}

+ (NSString *)pendingReportPath {
    if (!g_pendingReportPath) {
        g_pendingReportPath = [zs_documents_path() stringByAppendingPathComponent:@"zsingularity_crash_pending.log"];
    }
    return g_pendingReportPath;
}

+ (void)install {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *currentPath = [self currentReportPath];
    NSString *pendingPath = [self pendingReportPath];

    NSDictionary *currentAttributes = [fileManager attributesOfItemAtPath:currentPath error:nil];
    if ([currentAttributes fileSize] > 0) {
        [fileManager removeItemAtPath:pendingPath error:nil];
        [fileManager moveItemAtPath:currentPath toPath:pendingPath error:nil];
    }

    g_pendingFD = open(currentPath.UTF8String, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (g_pendingFD < 0) {
        ZLog(@"[ZCrashLogger] couldn't open %@ for writing - crash popup is disabled this run", currentPath);
    }

    NSString *path = [self crashLogPath];
    g_crashLogFD = open(path.UTF8String, O_CREAT | O_APPEND | O_WRONLY, 0644);
    if (g_crashLogFD < 0) {
        ZLog(@"[ZCrashLogger] couldn't open %@ for writing - crash logging is disabled this run", path);
    }

    if (g_crashLogFD < 0 && g_pendingFD < 0) return;

    uint32_t imageCount = _dyld_image_count();
    uintptr_t mainSlide = (imageCount > 0) ? (uintptr_t)_dyld_get_image_vmaddr_slide(0) : 0;

    Dl_info selfInfo;
    uintptr_t tweakSlide = 0;
    NSString *tweakPath = @"(unknown)";
    if (dladdr((const void *)&crash_signal_handler, &selfInfo) && selfInfo.dli_fname) {
        tweakPath = @(selfInfo.dli_fname);
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strcmp(name, selfInfo.dli_fname) == 0) {
                tweakSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
    }

    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *reportHeader = [NSString stringWithFormat:
        @"app: ZSingularity %s\ndevice: %s (%s %s)\nmain executable slide: 0x%lx\ntweak dylib slide: 0x%lx\n",
        ZS_VERSION_STRING, systemInfo.machine, systemInfo.sysname, systemInfo.release,
        (unsigned long)mainSlide, (unsigned long)tweakSlide];
    strlcpy(g_reportHeader, reportHeader.UTF8String ?: "", sizeof(g_reportHeader));

    if (g_crashLogFD >= 0) {
        NSString *header = [NSString stringWithFormat:
            @"\n=== ZCrashLogger installed ===\nmain executable slide: 0x%lx\ntweak dylib (%@) slide: 0x%lx\n",
            (unsigned long)mainSlide, tweakPath, (unsigned long)tweakSlide];
        const char *headerUtf8 = header.UTF8String;
        if (headerUtf8) write(g_crashLogFD, headerUtf8, strlen(headerUtf8));
        fsync(g_crashLogFD);
    }

    void *primeFrames[4];
    backtrace(primeFrames, 4);
    (void)time(NULL);

    stack_t ss;
    ss.ss_sp = g_altStack;
    ss.ss_size = sizeof(g_altStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    install_handlers();

    g_reinstallTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    // Unity / LiveContainer replace the uncaught-exception handler during
    // launch, which is why crashes showed up as a bare SIGABRT with no
    // exception name or reason. Re-claim it every 100ms for the first 30s
    // (the launch window), then back off to every 5s.
    dispatch_source_set_timer(g_reinstallTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC,
                              10 * NSEC_PER_MSEC);
    __block int reinstallTicks = 0;
    dispatch_source_set_event_handler(g_reinstallTimer, ^{
        install_handlers();
        if (++reinstallTicks == 300) {
            dispatch_source_set_timer(g_reinstallTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                      5 * NSEC_PER_SEC,
                                      1 * NSEC_PER_SEC);
        }
    });
    dispatch_resume(g_reinstallTimer);

    ZLog(@"[ZCrashLogger] installed - crash log path: %@", path);
}

+ (void)reinstallHandlersIfNeeded {
    if (g_crashLogFD < 0 && g_pendingFD < 0) return;
    install_handlers();
}

+ (NSDictionary<NSString *, id> *)pendingCrashReport {
    NSData *data = [NSData dataWithContentsOfFile:[self pendingReportPath]];
    if (data.length == 0) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (text.length == 0) return nil;

    NSString *signalName = nil;
    NSString *exceptionName = nil;
    long long timestamp = 0;
    BOOL inTrace = NO;
    NSMutableArray<NSString *> *display = [NSMutableArray array];

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"signal: "]) {
            signalName = [line substringFromIndex:8];
        } else if ([line hasPrefix:@"time: "]) {
            timestamp = [[line substringFromIndex:6] longLongValue];
        } else if ([line hasPrefix:@"name: "]) {
            exceptionName = [line substringFromIndex:6];
            [display addObject:[@"NSException " stringByAppendingString:exceptionName]];
        } else if ([line hasPrefix:@"reason: "]) {
            [display addObject:line];
        } else if ([line isEqualToString:@"backtrace:"] || [line isEqualToString:@"callStackSymbols:"]) {
            inTrace = YES;
        } else if ([line hasPrefix:@"=== end ==="]) {
            if (inTrace) [display addObject:@""];
            inTrace = NO;
        } else if (inTrace && line.length > 0) {
            [display addObject:line];
        }
    }

    NSString *trace = [[display componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trace.length > 20000) trace = [trace substringToIndex:20000];
    if (trace.length == 0) trace = @"(no stack trace was captured)";

    return @{
        @"signal": signalName ?: exceptionName ?: @"UNKNOWN",
        @"trace": trace,
        @"report": text,
        @"timestamp": @(timestamp),
    };
}

+ (void)clearPendingCrashReport {
    [NSFileManager.defaultManager removeItemAtPath:[self pendingReportPath] error:nil];
}

+ (void)killProcessWithSIGKILL {
    if (__sync_lock_test_and_set(&g_handling, 1) == 0) {
        write_crash_report(SIGKILL, NULL, 0);
    }
    kill(getpid(), SIGKILL);
}

@end

__attribute__((constructor))
static void ZCrashLoggerConstructor(void) {
    [ZCrashLogger install];
}

#pragma mark - ZSyslogController

@interface ZSyslogController ()
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) NSPipe *pipe;
@property (nonatomic, assign) int stdoutCopy;
@property (nonatomic, assign) int stderrCopy;
@property (nonatomic, assign) BOOL restoredDescriptors;
@property (nonatomic, strong) NSMutableData *pendingBytes;
@end

@implementation ZSyslogController

+ (instancetype)sharedController {
    static ZSyslogController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [ZSyslogController new];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stdoutCopy = -1;
        _stderrCopy = -1;
    }
    return self;
}

- (BOOL)start {
    if (self.running) {
        ZLog(@"[ZSyslogController] start called while already running, ignoring");
        return YES;
    }

    int outCopy = dup(STDOUT_FILENO);
    int errCopy = dup(STDERR_FILENO);
    if (outCopy < 0 || errCopy < 0) {
        ZLog(@"[ZSyslogController] start failed: dup() of std descriptors failed (out=%d err=%d)", outCopy, errCopy);
        if (outCopy >= 0) close(outCopy);
        if (errCopy >= 0) close(errCopy);
        return NO;
    }

    NSPipe *pipe = [NSPipe pipe];
    if (!pipe) {
        ZLog(@"[ZSyslogController] start failed: could not allocate NSPipe");
        close(outCopy);
        close(errCopy);
        return NO;
    }

    int writeFD = pipe.fileHandleForWriting.fileDescriptor;
    if (dup2(writeFD, STDOUT_FILENO) < 0 || dup2(writeFD, STDERR_FILENO) < 0) {
        ZLog(@"[ZSyslogController] start failed: dup2() redirect of std descriptors failed, restoring originals");
        dup2(outCopy, STDOUT_FILENO);
        dup2(errCopy, STDERR_FILENO);
        close(outCopy);
        close(errCopy);
        return NO;
    }

    self.stdoutCopy = outCopy;
    self.stderrCopy = errCopy;
    self.pipe = pipe;
    self.restoredDescriptors = NO;

    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;

        ZSyslogController *strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSString *> *lines = [strongSelf extractLinesFromData:data];
        if (lines.count > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ZSyslogController *mainSelf = weakSelf;
                if (!mainSelf) return;
                if (mainSelf.linesHandler) {
                    mainSelf.linesHandler(lines);
                } else if (mainSelf.lineHandler) {
                    for (NSString *line in lines) mainSelf.lineHandler(line);
                }
            });
        }

        int fd = strongSelf.stdoutCopy >= 0 ? strongSelf.stdoutCopy : STDOUT_FILENO;

        ssize_t remaining = (ssize_t)data.length;
        const uint8_t *bytes = data.bytes;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, (size_t)remaining);
            if (written <= 0) break;
            bytes += written;
            remaining -= written;
        }
    };

    self.running = YES;
    ZLog(@"[ZSyslogController] started, stdout/stderr now piped through syslog console");
    return YES;
}

- (NSArray<NSString *> *)extractLinesFromData:(NSData *)data {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @synchronized (self) {
        if (!self.pendingBytes) self.pendingBytes = [NSMutableData data];
        [self.pendingBytes appendData:data];

        const uint8_t *bytes = self.pendingBytes.bytes;
        NSUInteger length = self.pendingBytes.length;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] != '\n' && bytes[i] != '\r') continue;
            if (i > start) {
                NSString *line = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSISOLatin1StringEncoding];
                if (line.length > 0) [lines addObject:line];
            }
            start = i + 1;
        }
        if (start > 0) [self.pendingBytes replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];

        if (self.pendingBytes.length > 65536) {
            NSString *line = [[NSString alloc] initWithData:self.pendingBytes encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:self.pendingBytes encoding:NSISOLatin1StringEncoding];
            if (line.length > 0) [lines addObject:line];
            [self.pendingBytes setLength:0];
        }
    }
    return lines;
}

- (void)stop {
    if (!self.pipe && self.stdoutCopy < 0 && self.stderrCopy < 0) {
        self.running = NO;
        return;
    }

    ZLog(@"[ZSyslogController] stopping, restoring original stdout/stderr descriptors");

    NSPipe *pipe = self.pipe;
    if (pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil;
    }

    if (!self.restoredDescriptors) {
        if (self.stdoutCopy >= 0) dup2(self.stdoutCopy, STDOUT_FILENO);
        if (self.stderrCopy >= 0) dup2(self.stderrCopy, STDERR_FILENO);
        self.restoredDescriptors = YES;
    }

    if (self.stdoutCopy >= 0) {
        close(self.stdoutCopy);
        self.stdoutCopy = -1;
    }
    if (self.stderrCopy >= 0) {
        close(self.stderrCopy);
        self.stderrCopy = -1;
    }

    self.pipe = nil;
    @synchronized (self) {
        self.pendingBytes = nil;
    }
    self.running = NO;
}

- (void)dealloc {
    [self stop];
}

@end

