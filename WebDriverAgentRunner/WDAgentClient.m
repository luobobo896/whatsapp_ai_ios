#import "WDAgentClient.h"

#import <Security/Security.h>

static NSTimeInterval const kHeartbeatInterval = 20.0;
static NSString *const kKeychainService = @"com.whatsappai.deviceagent.wda";
static NSString *const kKeychainAccountToken = @"deviceToken";

static NSArray<NSNumber *> *kReconnectBackoff(void)
{
  return @[@1, @2, @4, @8, @16, @30];
}

@interface WDAgentClient ()
@property(nonatomic, copy) NSString *platformURL;
@property(nonatomic, copy) NSString *enrollmentCode;
@property(nonatomic, copy) NSString *installationID;
@property(nonatomic, copy) NSString *osVersion;
@property(nonatomic, copy) NSString *deviceModel;
@property(nonatomic, copy) NSString *locale;
@property(nonatomic, copy, nullable) NSString *wdaURL;
@property(nonatomic, copy, nullable) WDAgentEnrollCompletion completion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSString *deviceToken;
@property(nonatomic, assign) BOOL heartbeatStarted;
@property(nonatomic, assign) BOOL heartbeatStopped;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *webSocketTask;
@property(nonatomic, assign) BOOL wsRunning;
@property(nonatomic, assign) BOOL manualClose;
@property(nonatomic, assign) NSUInteger wsReconnectIndex;
@property(nonatomic, assign) NSInteger msgCounter;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WDAgentClient

- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.whatsappai.wda.agent", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    _session = [NSURLSession sessionWithConfiguration:config];
  }
  return self;
}

- (void)startWithPlatformURL:(NSString *)platformURL
                  enrollCode:(NSString *)enrollCode
             installationID:(NSString *)installationID
                  osVersion:(NSString *)osVersion
               deviceModel:(NSString *)deviceModel
                    locale:(NSString *)locale
                    wdaURL:(nullable NSString *)wdaURL
                completion:(WDAgentEnrollCompletion)completion
{
  self.platformURL = platformURL;
  self.enrollmentCode = enrollCode;
  self.installationID = installationID;
  self.osVersion = osVersion;
  self.deviceModel = deviceModel;
  self.locale = locale;
  self.wdaURL = wdaURL;
  self.completion = completion;
  [self enroll];
}

- (void)stop
{
  self.wsRunning = NO;
  self.manualClose = YES;
  [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
  self.webSocketTask = nil;
  self.heartbeatStopped = YES;
  self.completion = nil;
}

// MARK: - 注册

- (void)enroll
{
  NSURL *url = [NSURL URLWithString:[self.platformURL stringByAppendingString:@"/api/ios-agent/v1/enroll"]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSDictionary *body = @{
    @"enrollmentCode": self.enrollmentCode ?: @"",
    @"installationId": self.installationID ?: @"",
    @"appVersion": @"1.0",
    @"osVersion": self.osVersion ?: @"",
    @"deviceModel": self.deviceModel ?: @"",
    @"locale": self.locale ?: @"",
    @"platform": @"ios",
    @"deviceUdids": @[],
  };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (error || http.statusCode / 100 != 2) {
      NSError *err = error ?: [NSError errorWithDomain:@"WDAgentClient"
                                                  code:http.statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"enroll HTTP %ld", (long)http.statusCode]}];
      [strongSelf finishEnrollWithError:err];
      return;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSString *deviceID = json[@"deviceId"];
    NSString *token = json[@"deviceToken"];
    NSInteger configVersion = [json[@"config"][@"configVersion"] integerValue];
    if (deviceID.length == 0 || token.length == 0) {
      [strongSelf finishEnrollWithError:[NSError errorWithDomain:@"WDAgentClient"
                                                            code:-1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"enroll 响应缺少 deviceId/deviceToken"}]];
      return;
    }
    strongSelf.deviceToken = token;
    [strongSelf saveToken:token];
    [strongSelf startHeartbeat];
    [strongSelf startWebSocket];
    WDAgentEnrollCompletion completion = strongSelf.completion;
    strongSelf.completion = nil;
    if (completion) {
      completion(deviceID, configVersion, nil);
    }
  }];
  [task resume];
}

- (void)finishEnrollWithError:(NSError *)error
{
  WDAgentEnrollCompletion completion = self.completion;
  self.completion = nil;
  if (completion) {
    completion(nil, 0, error);
  }
}

// MARK: - 心跳（每 20s 上报 /status，并发送 WSS agent:heartbeat 帧）

- (void)startHeartbeat
{
  if (self.heartbeatStarted) {
    return;
  }
  self.heartbeatStarted = YES;
  self.heartbeatStopped = NO;
  [self scheduleNextHeartbeat];
}

- (void)scheduleNextHeartbeat
{
  if (self.heartbeatStopped) {
    return;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeartbeatInterval * NSEC_PER_SEC)), self.queue, ^{
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf || strongSelf.heartbeatStopped) {
      return;
    }
    [strongSelf reportStatus];
    [strongSelf sendWSHeartbeat];
    [strongSelf scheduleNextHeartbeat];
  });
}

- (void)reportStatus
{
  if (self.deviceToken.length == 0) {
    return;
  }
  NSURL *url = [NSURL URLWithString:[self.platformURL stringByAppendingString:@"/api/ios-agent/v1/status"]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken] forHTTPHeaderField:@"Authorization"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
    @"appStatus": @"online",
    @"vpnPhase": @"stopped",
    @"peerCount": @0,
    @"wdaUrl": self.wdaURL ?: @"",
    @"osVersion": self.osVersion ?: @"",
    @"deviceModel": self.deviceModel ?: @"",
    @"locale": self.locale ?: @"",
  } options:0 error:NULL];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (http.statusCode == 401) {
      NSLog(@"[WDAgent] 心跳 401：token 失效，停止 agent");
      [strongSelf stop];
    }
  }];
  [task resume];
}

// MARK: - WSS 长连接

- (void)startWebSocket
{
  if (self.webSocketTask) {
    return;
  }
  NSURLComponents *components = [NSURLComponents componentsWithString:self.platformURL];
  if ([components.scheme isEqualToString:@"https"]) {
    components.scheme = @"wss";
  } else if ([components.scheme isEqualToString:@"http"]) {
    components.scheme = @"ws";
  } else {
    return;
  }
  components.path = @"/api/ios-agent/v1/ws";
  NSURL *wsURL = components.URL;
  if (wsURL == nil) {
    return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:wsURL];
  [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken] forHTTPHeaderField:@"Authorization"];

  NSURLSessionWebSocketTask *task = [self.session webSocketTaskWithRequest:request];
  self.webSocketTask = task;
  self.wsRunning = YES;
  self.manualClose = NO;
  [task resume];
  self.wsReconnectIndex = 0;

  [self sendFrameType:@"agent:hello" payload:@{
    @"app": @"WhatsAppDeviceAgent",
    @"os": self.osVersion ?: @"",
    @"model": self.deviceModel ?: @"",
    @"locale": self.locale ?: @"",
    @"configVersion": @1,
  }];
  [self receiveLoop:task];
}

- (void)receiveLoop:(NSURLSessionWebSocketTask *)task
{
  __weak typeof(self) weakSelf = self;
  [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    if (error) {
      if (strongSelf.wsRunning && !strongSelf.manualClose) {
        strongSelf.webSocketTask = nil;
        [strongSelf reconnect];
      }
      return;
    }
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
      [strongSelf handleFrame:message.string];
    }
    if (strongSelf.wsRunning) {
      [strongSelf receiveLoop:task];
    }
  }];
}

- (void)handleFrame:(nullable NSString *)text
{
  if (text.length == 0) {
    return;
  }
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSString *type = json[@"type"];
  if ([type isEqualToString:@"server:diagnostic_request"]) {
    NSString *requestID = json[@"payload"][@"requestId"];
    if (requestID.length > 0) {
      [self sendFrameType:@"agent:status" payload:@{
        @"configVersion": @1,
        @"appStatus": @"online",
        @"wdaUrl": self.wdaURL ?: @"",
        @"requestId": requestID,
      }];
    }
  }
  // server:ack / server:disconnect 无需处理
}

- (void)reconnect
{
  NSArray<NSNumber *> *backoff = kReconnectBackoff();
  NSUInteger index = MIN(self.wsReconnectIndex, backoff.count - 1);
  self.wsReconnectIndex += 1;
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff[index].doubleValue * NSEC_PER_SEC)), self.queue, ^{
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.wsRunning || strongSelf.manualClose || strongSelf.webSocketTask) {
      return;
    }
    [strongSelf startWebSocket];
  });
}

- (void)sendWSHeartbeat
{
  [self sendFrameType:@"agent:heartbeat" payload:@{
    @"foreground": @YES,
    @"vpnPhase": @"stopped",
    @"peerCount": @0,
    @"appStatus": @"online",
    @"wdaUrl": self.wdaURL ?: @"",
  }];
}

- (void)sendFrameType:(NSString *)type payload:(NSDictionary *)payload
{
  NSURLSessionWebSocketTask *task = self.webSocketTask;
  if (!task) {
    return;
  }
  self.msgCounter += 1;
  NSDictionary *envelope = @{
    @"v": @1,
    @"type": type,
    @"msgId": [NSString stringWithFormat:@"%@:%ld", self.installationID, (long)self.msgCounter],
    @"sentAt": [self iso8601Now],
    @"payload": payload ?: @{},
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
  [task sendMessage:message completionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"[WDAgent] WSS 发送失败: %@", error.localizedDescription);
    }
  }];
}

- (NSString *)iso8601Now
{
  static NSISO8601DateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
  });
  return [formatter stringFromDate:[NSDate date]];
}

// MARK: - Keychain（deviceToken）

- (void)saveToken:(NSString *)token
{
  NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: kKeychainService,
    (__bridge id)kSecAttrAccount: kKeychainAccountToken,
  };
  NSDictionary *attributes = @{
    (__bridge id)kSecValueData: data,
    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
  };
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
  if (status == errSecItemNotFound) {
    NSMutableDictionary *add = [query mutableCopy];
    [add addEntriesFromDictionary:attributes];
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  }
}

@end
