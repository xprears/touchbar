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
@end
// 注：曾经想用 addSystemTrayItem: / removeSystemTrayItem: 把按钮塞进右侧控制条
// （那是唯一能与输入法候选条天然并存的位置）。**已证伪**：这两个选择子在
// NSTouchBar 上不存在 —— 类和实例的 respondsToSelector 都是 false，
// 运行时枚举 NSTouchBar 元类只剩下 dismissSystemModalTouchBar: /
// minimizeSystemModalTouchBar: / presentSystemModalTouchBar:systemTrayItemIdentifier: /
// presentSystemModalTouchBar:placement:systemTrayItemIdentifier: 这 4 个相关方法，
// 且**全部是 v（void）返回**。别再往这条路上试。
