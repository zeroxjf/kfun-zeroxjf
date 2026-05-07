//
//  DSStatBarAgent.m
//  SpringBoard-resident StatBar agent.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <math.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;

static void *g_iokit = NULL;
static CFMutableDictionaryRef (*pIOServiceMatching)(const char *) = NULL;
static io_service_t (*pIOServiceGetMatchingService)(mach_port_t, CFDictionaryRef) = NULL;
static CFTypeRef (*pIORegistryEntryCreateCFProperty)(io_service_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
static kern_return_t (*pIOObjectRelease)(io_object_t) = NULL;

static BOOL ensure_iokit_symbols(void)
{
    if (!g_iokit) {
        g_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        if (!g_iokit) return NO;
        pIOServiceMatching               = dlsym(g_iokit, "IOServiceMatching");
        pIOServiceGetMatchingService     = dlsym(g_iokit, "IOServiceGetMatchingService");
        pIORegistryEntryCreateCFProperty = dlsym(g_iokit, "IORegistryEntryCreateCFProperty");
        pIOObjectRelease                 = dlsym(g_iokit, "IOObjectRelease");
    }
    return pIOServiceMatching && pIOServiceGetMatchingService &&
           pIORegistryEntryCreateCFProperty && pIOObjectRelease;
}

static double read_battery_temp_c(void)
{
    if (!ensure_iokit_symbols()) return -1.0;
    io_service_t svc = pIOServiceGetMatchingService(MACH_PORT_NULL,
                                                    pIOServiceMatching("AppleSmartBattery"));
    if (svc == MACH_PORT_NULL) return -1.0;

    double tempC = -1.0;
    CFNumberRef prop = (CFNumberRef)pIORegistryEntryCreateCFProperty(svc,
                                                                     CFSTR("Temperature"),
                                                                     kCFAllocatorDefault, 0);
    if (prop) {
        int64_t raw = 0;
        if (CFNumberGetValue(prop, kCFNumberSInt64Type, &raw)) {
            tempC = (double)raw / 100.0;
        }
        CFRelease(prop);
    }
    pIOObjectRelease(svc);
    return tempC;
}

static double read_free_ram_gb(void)
{
    mach_port_t host = mach_host_self();
    vm_statistics64_data_t stat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(host, HOST_VM_INFO64,
                                         (host_info64_t)&stat, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (kr != KERN_SUCCESS) return -1.0;
    uint64_t bytes = (uint64_t)stat.free_count * (uint64_t)vm_kernel_page_size;
    return (double)bytes / (1024.0 * 1024.0 * 1024.0);
}

static NSString *pad_left_visual(NSString *s, NSUInteger width)
{
    if (!s) s = @"";
    NSUInteger len = s.length;
    if (len >= width) return s;

    NSMutableString *out = [NSMutableString stringWithCapacity:width];
    for (NSUInteger i = len; i < width; i++) {
        [out appendString:@"\u2007"];
    }
    [out appendString:s];
    return out;
}

static BOOL read_net_totals(uint64_t *ibytes, uint64_t *obytes)
{
    if (!ibytes || !obytes) return NO;
    *ibytes = 0;
    *obytes = 0;

    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) return NO;

    for (struct ifaddrs *ifa = head; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_data || !ifa->ifa_name) continue;
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        if ((ifa->ifa_flags & IFF_LOOPBACK) != 0) continue;
        if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;

        const struct if_data *data = (const struct if_data *)ifa->ifa_data;
        *ibytes += (uint64_t)data->ifi_ibytes;
        *obytes += (uint64_t)data->ifi_obytes;
    }

    freeifaddrs(head);
    return YES;
}

static double now_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static NSString *format_net_slot(double kbValue)
{
    NSString *token = nil;
    if (kbValue < 1.0) {
        token = [NSString stringWithFormat:@"%lldB", (long long)llround(kbValue * 1024.0)];
    } else if (kbValue < 1024.0) {
        token = [NSString stringWithFormat:@"%lldKB", (long long)llround(kbValue)];
    } else {
        token = [NSString stringWithFormat:@"%lldMB", (long long)llround(kbValue / 1024.0)];
    }
    return pad_left_visual(token, 6);
}

@interface DSStatBarAgent : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL celsius;
@property (nonatomic) BOOL hideNet;
@property (nonatomic) BOOL havePrevNet;
@property (nonatomic) uint64_t prevIn;
@property (nonatomic) uint64_t prevOut;
@property (nonatomic) double prevTime;
@property (nonatomic) uint64_t tick;
+ (instancetype)shared;
- (void)startWithCelsius:(BOOL)celsius hideNet:(BOOL)hideNet;
- (void)stop;
@end

@implementation DSStatBarAgent

+ (instancetype)shared
{
    static DSStatBarAgent *agent = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        agent = [DSStatBarAgent new];
    });
    return agent;
}

- (UIWindowScene *)activeWindowScene
{
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.windows.count > 0) return windowScene;
    }
    return nil;
}

- (double)overlayWidth
{
    return self.hideNet ? 140.0 : 260.0;
}

- (void)applyLayout
{
    if (!self.window || !self.label) return;

    UIScreen *screen = self.window.windowScene.screen ?: UIScreen.mainScreen;
    CGFloat screenWidth = screen.bounds.size.width > 0 ? screen.bounds.size.width : 440.0;
    CGFloat width = (CGFloat)[self overlayWidth];
    CGFloat height = 18.0;
    CGFloat x = (screenWidth - width) / 2.0;
    CGFloat y = 54.0;

    self.window.frame = CGRectMake(x, y, width, height);
    self.window.windowLevel = UIWindowLevelStatusBar + 100000.0;
    self.window.userInteractionEnabled = NO;
    self.window.backgroundColor = UIColor.clearColor;

    self.label.frame = CGRectMake(0.0, 0.0, width, height);
    self.label.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.numberOfLines = 1;
    self.label.backgroundColor = UIColor.blackColor;
    self.label.textColor = UIColor.whiteColor;
    self.label.layer.cornerRadius = height / 2.0;
    self.label.layer.masksToBounds = YES;
}

- (BOOL)ensureOverlay
{
    if (self.window && self.label) {
        [self applyLayout];
        self.window.hidden = NO;
        return YES;
    }

    UIWindowScene *scene = [self activeWindowScene];
    if (!scene) {
        printf("[DSSTAT] no active UIWindowScene\n");
        return NO;
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    [window addSubview:label];

    self.window = window;
    self.label = label;
    [self applyLayout];
    window.hidden = NO;
    printf("[DSSTAT] overlay installed win=%p label=%p\n", window, label);
    return YES;
}

- (void)readNetDown:(double *)downKB up:(double *)upKB
{
    if (downKB) *downKB = 0.0;
    if (upKB) *upKB = 0.0;

    uint64_t totalIn = 0;
    uint64_t totalOut = 0;
    double now = now_seconds();
    if (now <= 0.0 || !read_net_totals(&totalIn, &totalOut)) return;

    if (self.havePrevNet && now > self.prevTime) {
        uint64_t din = (totalIn >= self.prevIn) ? (totalIn - self.prevIn) : 0;
        uint64_t dout = (totalOut >= self.prevOut) ? (totalOut - self.prevOut) : 0;
        double dt = now - self.prevTime;
        if (downKB) *downKB = ((double)din / dt) / 1024.0;
        if (upKB) *upKB = ((double)dout / dt) / 1024.0;
    }

    self.prevIn = totalIn;
    self.prevOut = totalOut;
    self.prevTime = now;
    self.havePrevNet = YES;
}

- (NSString *)statusText
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    double tempC = read_battery_temp_c();
    if (tempC > 0) {
        double v = self.celsius ? tempC : (tempC * 9.0 / 5.0 + 32.0);
        NSString *num = [NSString stringWithFormat:@"%.2f", v];
        [parts addObject:[NSString stringWithFormat:@"%@\u00B0%c",
                          pad_left_visual(num, 6), self.celsius ? 'C' : 'F']];
    }

    double freeGB = read_free_ram_gb();
    if (freeGB > 0) {
        if (freeGB < 1.0) {
            NSString *num = [NSString stringWithFormat:@"%.2f", freeGB * 1024.0];
            [parts addObject:[NSString stringWithFormat:@"%@MB", pad_left_visual(num, 6)]];
        } else {
            NSString *num = [NSString stringWithFormat:@"%.2f", freeGB];
            [parts addObject:[NSString stringWithFormat:@"%@GB", pad_left_visual(num, 6)]];
        }
    }

    if (!self.hideNet) {
        double downKB = 0.0;
        double upKB = 0.0;
        [self readNetDown:&downKB up:&upKB];
        [parts addObject:[NSString stringWithFormat:@"\u2193%@ \u2191%@",
                          format_net_slot(downKB), format_net_slot(upKB)]];
    }

    if (parts.count == 0) return @"n/a";
    return [parts componentsJoinedByString:@" | "];
}

- (void)tick:(NSTimer *)timer
{
    if (![self ensureOverlay]) return;
    self.label.text = [self statusText];
    self.tick++;
    if (self.tick <= 3 || (self.tick % 10) == 0) {
        printf("[DSSTAT] tick=%llu text='%s'\n",
               (unsigned long long)self.tick, self.label.text.UTF8String ?: "");
    }
}

- (void)startWithCelsius:(BOOL)celsius hideNet:(BOOL)hideNet
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.celsius = celsius;
        self.hideNet = hideNet;
        [self ensureOverlay];
        [self tick:nil];

        if (!self.timer) {
            self.timer = [NSTimer timerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(tick:)
                                               userInfo:nil
                                                repeats:YES];
            self.timer.tolerance = 0.1;
            [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
            printf("[DSSTAT] resident timer started\n");
        } else {
            printf("[DSSTAT] resident config updated celsius=%d hideNet=%d\n",
                   self.celsius, self.hideNet);
        }
    });
}

- (void)stop
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.timer invalidate];
        self.timer = nil;
        self.window.hidden = YES;
        [self.label removeFromSuperview];
        self.label = nil;
        self.window = nil;
        printf("[DSSTAT] resident timer stopped\n");
    });
}

@end

__attribute__((visibility("default")))
int ds_statbar_agent_start(int celsius, int hideNet)
{
    [[DSStatBarAgent shared] startWithCelsius:(celsius != 0) hideNet:(hideNet != 0)];
    return 1;
}

__attribute__((visibility("default")))
int ds_statbar_agent_stop(void)
{
    [[DSStatBarAgent shared] stop];
    return 1;
}

__attribute__((constructor))
static void ds_statbar_agent_ctor(void)
{
    printf("[DSSTAT] dylib loaded\n");
}
