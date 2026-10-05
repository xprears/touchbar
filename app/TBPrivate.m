#import "TBPrivate.h"
#import <objc/message.h>

@implementation TBPrivate

+ (BOOL)respondsToPresent {
    return [NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)];
}

+ (BOOL)present:(NSTouchBar *)bar placement:(int)placement {
    SEL sel = @selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:);
    if (![NSTouchBar respondsToSelector:sel]) return NO;
    // 用 performSelector 走消息派发。参数里 placement 是 int(64)，
    // 直接写成 (id)placement 会被当成指针，这里包成 NSNumber 由 ObjC 侧转。
    BOOL r = ((BOOL (*)(id, SEL, id, long, id))objc_msgSend)([NSTouchBar class], sel, bar, (long)placement, nil);
    NSLog(@"[TBPrivate] present placement=%d ret=%d", placement, r);
    return r;
}

+ (BOOL)dismiss:(NSTouchBar *)bar {
    SEL sel = @selector(dismissSystemModalTouchBar:);
    if (![NSTouchBar respondsToSelector:sel]) return NO;
    BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], sel, bar);
    NSLog(@"[TBPrivate] dismiss ret=%d", r);
    return r;
}

+ (BOOL)minimize:(NSTouchBar *)bar {
    SEL sel = @selector(minimizeSystemModalTouchBar:);
    if (![NSTouchBar respondsToSelector:sel]) return NO;
    BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], sel, bar);
    NSLog(@"[TBPrivate] dismiss ret=%d", r);
    return r;
}

@end
