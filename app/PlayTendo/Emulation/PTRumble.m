#import "PTRumble.h"
#import <os/lock.h>

static os_unfair_lock rumbleLock = OS_UNFAIR_LOCK_INIT;
static void (^rumbleHandler)(unsigned int, float, float);

void PTRumbleSet(unsigned int port, float strong, float weak) {
    os_unfair_lock_lock(&rumbleLock);
    void (^handler)(unsigned int, float, float) = rumbleHandler;
    os_unfair_lock_unlock(&rumbleLock);
    if (handler) handler(port, strong, weak);
}

void PTRumbleSetHandler(void (^handler)(unsigned int, float, float)) {
    os_unfair_lock_lock(&rumbleLock);
    rumbleHandler = [handler copy];
    os_unfair_lock_unlock(&rumbleLock);
}
