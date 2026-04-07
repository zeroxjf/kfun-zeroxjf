//
//  LogTextView.m
//  darksword-kexploit-fun
//
//  Created by seo on 4/7/26.
//

#import "LogTextView.h"
#include <pthread.h>
#include <string.h>

#define LOG_MAX_LINES   50000
#define LOG_TRIM_TO     30000
#define LOG_LINE_SIZE   2560

static char            log_buf[LOG_MAX_LINES][LOG_LINE_SIZE];
static int             log_count = 0;
static int             log_dirty = 0;
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

void log_init(void) {
    pthread_mutex_lock(&log_mutex);
    log_count = 0;
    log_dirty = 0;
    pthread_mutex_unlock(&log_mutex);
}

static char line_buf[LOG_LINE_SIZE];
static int  line_pos = 0;
void log_write(const char *msg) {
    pthread_mutex_lock(&log_mutex);
    
    while (*msg) {
        if (*msg == '\n') {
            line_buf[line_pos] = '\0';
            
            if (log_count >= LOG_MAX_LINES) {
                memmove(log_buf[0], log_buf[LOG_MAX_LINES - LOG_TRIM_TO], LOG_TRIM_TO * LOG_LINE_SIZE);
                log_count = LOG_TRIM_TO;
            }
            strlcpy(log_buf[log_count], line_buf, LOG_LINE_SIZE);
            log_count++;
            log_dirty = 1;
            line_pos = 0;
        } else {
            if (line_pos < LOG_LINE_SIZE - 1) {
                line_buf[line_pos++] = *msg;
            }
        }
        msg++;
    }
    
    pthread_mutex_unlock(&log_mutex);
}

static NSString *log_snapshot(void) {
    pthread_mutex_lock(&log_mutex);
    if (!log_dirty) {
        pthread_mutex_unlock(&log_mutex);
        return nil;
    }
    log_dirty = 0;
    NSMutableString *s = [[NSMutableString alloc] initWithCapacity:log_count * 80];
    for (int i = 0; i < log_count; i++) {
        [s appendFormat:@"%s\n", log_buf[i]];
    }
    pthread_mutex_unlock(&log_mutex);
    return s;
}

@interface LogTextView ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation LogTextView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self setup];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setup];
    return self;
}

- (void)setup {
    self.editable = NO;
    self.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.backgroundColor = UIColor.blackColor;
    self.textColor = UIColor.greenColor;
    
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _displayLink.preferredFramesPerSecond = 60;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick {
    NSString *snap = log_snapshot();
    if (!snap) return;
    self.text = snap;
    [self scrollRangeToVisible:NSMakeRange(snap.length, 0)];
}

- (void)removeFromSuperview {
    [_displayLink invalidate];
    _displayLink = nil;
    [super removeFromSuperview];
}

@end
