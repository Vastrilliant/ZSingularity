#import "ZSDiagnostics.h"
#import "ZTweakLog.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>

#pragma mark - ZCrashLogger
#import <string.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

static int g_crashLogFD = -1;
static NSString *g_crashLogPath = nil;

static const int kHandledSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
static const int kHandledSignalCount = sizeof(kHandledSignals) / sizeof(kHandledSignals[0]);

static uint8_t g_altStack[64 * 1024];

#pragma mark - Async-signal-safe helpers

static void safe_write_str(const char *s) {
    if (g_crashLogFD < 0 || !s) return;
    write(g_crashLogFD, s, strlen(s));
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

static const char *name_for_signal(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        default:      return "UNKNOWN";
    }
}

static void crash_signal_handler(int sig, siginfo_t *info, void *uctx) {
    (void)uctx;

    safe_write_str("\n=== ZCrashLogger: fatal signal ===\n");
    safe_write_str("signal: ");
    safe_write_str(name_for_signal(sig));
    safe_write_str("\n");

    if (info) {
        safe_write_str("si_addr (faulting address, SIGSEGV/SIGBUS only - meaningless for other signals): ");
        safe_write_hex((uintptr_t)info->si_addr);
        safe_write_str("\n");
    }

    safe_write_str("backtrace:\n");

    void *frames[64];
    int frameCount = backtrace(frames, 64);
    if (frameCount > 0) {
        backtrace_symbols_fd(frames, frameCount, g_crashLogFD);
    } else {
        safe_write_str("(backtrace() returned no frames)\n");
    }

    safe_write_str("=== end ===\n");

    fsync(g_crashLogFD);

    signal(sig, SIG_DFL);
    raise(sig);
}

#pragma mark - Uncaught NSException handler

static void uncaught_exception_handler(NSException *exception) {
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"\n=== ZCrashLogger: uncaught NSException ===\nname: %@\nreason: %@\ncallStackSymbols:\n%@\n=== end ===\n",
        exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    const char *utf8 = log.UTF8String;
    if (g_crashLogFD >= 0 && utf8) {
        write(g_crashLogFD, utf8, strlen(utf8));
        fsync(g_crashLogFD);
    }
    ZLog(@"%@", log);

}

@implementation ZCrashLogger

+ (NSString *)crashLogPath {
    if (!g_crashLogPath) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        g_crashLogPath = [docs stringByAppendingPathComponent:@"zsingularity_crash.log"];
    }
    return g_crashLogPath;
}

+ (void)install {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSString *path = [self crashLogPath];
    g_crashLogFD = open(path.UTF8String, O_CREAT | O_APPEND | O_WRONLY, 0644);
    if (g_crashLogFD < 0) {
        ZLog(@"[ZCrashLogger] couldn't open %@ for writing - crash logging is disabled this run", path);
        return;
    }

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

    NSString *header = [NSString stringWithFormat:
        @"\n=== ZCrashLogger installed ===\nmain executable slide: 0x%lx\ntweak dylib (%@) slide: 0x%lx\n",
        (unsigned long)mainSlide, tweakPath, (unsigned long)tweakSlide];
    const char *headerUtf8 = header.UTF8String;
    if (headerUtf8) write(g_crashLogFD, headerUtf8, strlen(headerUtf8));
    fsync(g_crashLogFD);

    stack_t ss;
    ss.ss_sp = g_altStack;
    ss.ss_size = sizeof(g_altStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = crash_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;

    for (int i = 0; i < kHandledSignalCount; i++) {
        sigaction(kHandledSignals[i], &action, NULL);
    }

    NSSetUncaughtExceptionHandler(&uncaught_exception_handler);

    ZLog(@"[ZCrashLogger] installed - crash log path: %@", path);
}

@end

#pragma mark - ZSyslogController

@interface ZSyslogController ()
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) NSPipe *pipe;
@property (nonatomic, assign) int stdoutCopy;
@property (nonatomic, assign) int stderrCopy;
@property (nonatomic, assign) BOOL restoredDescriptors;
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

        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str.length > 0) {

            NSArray<NSString *> *parts = [str componentsSeparatedByCharactersInSet:
                                           [NSCharacterSet newlineCharacterSet]];
            for (NSString *part in parts) {
                if (part.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    ZSyslogController *mainSelf = weakSelf;
                    if (mainSelf.lineHandler) {
                        mainSelf.lineHandler(part);
                    }
                });
            }
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
    self.running = NO;
}

- (void)dealloc {
    [self stop];
}

@end

