/**
 * WhatsAppDeviceAgent：WDA 启动时在后台完成平台注册 / 心跳 / WSS 长连接。
 *
 * 配置来自环境变量（与 WDA 自身 USE_PORT 等一致，经 xcodebuild test 传入 runner）：
 *   WDA_PLATFORM_URL   平台地址，默认 https://hk.hsddns.com
 *   WDA_ENROLL_CODE    一次性注册码（必填；缺省时 agent 不启动，WDA 保持纯净）
 *   WDA_INSTALLATION_ID 可选，覆盖本地持久化的设备 ID
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WDAgent : NSObject

+ (instancetype)sharedAgent;

/// 从环境变量读取配置并异步启动；未配置注册码返回 NO。
- (BOOL)startWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
