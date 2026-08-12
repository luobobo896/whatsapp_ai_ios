#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WDAgentEnrollCompletion)(NSString *_Nullable deviceID, NSInteger configVersion, NSError *_Nullable error);

/// 网络客户端：注册 enroll -> 20s 心跳 /status -> WSS 长连接（hello/heartbeat/ack）。
@interface WDAgentClient : NSObject

- (void)startWithPlatformURL:(NSString *)platformURL
                  enrollCode:(NSString *)enrollCode
             installationID:(NSString *)installationID
                  osVersion:(NSString *)osVersion
               deviceModel:(NSString *)deviceModel
                    locale:(NSString *)locale
                    wdaURL:(nullable NSString *)wdaURL
                completion:(WDAgentEnrollCompletion)completion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
