// Touch Bar 私有 API 的 Objective-C 桥接。
// 为什么不写在 Swift 里：
//   presentSystemModalTouchBar:placement:systemTrayItemIdentifier: 是 3 参数私有类方法，
//   Swift 既没有声明（SDK 里没有），perform 只能带 2 个参数，NSInvocation 被标 unavailable，
//   而用 unsafeBitCast 自己取 IMP 会因签名不匹配直接崩溃（已实测）。
//   ObjC 里就是一次正常的消息派发，编译器不校验，最稳。
#import <Cocoa/Cocoa.h>

@interface TBPrivate : NSObject
+ (BOOL)present:(NSTouchBar *)bar placement:(int)placement;
+ (BOOL)dismiss:(NSTouchBar *)bar;
+ (BOOL)minimize:(NSTouchBar *)bar;
+ (BOOL)respondsToPresent;
@end
