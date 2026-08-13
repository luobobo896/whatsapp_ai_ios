#import "WDAgentClient.h"

#import <Security/Security.h>

static NSTimeInterval const kHeartbeatInterval = 20.0;
static NSString *const kKeychainService = @"com.whatsappai.deviceagent.wda";
static NSString *const kKeychainAccountToken = @"deviceToken";

static NSArray<NSNumber *> *kBackoff(void)
{
  return @[@1, @2, @4, @8, @16, @30];
}

/// 服务端下发的 WSS 关闭码：永久性失败，不应自动重连。
static BOOL kIsTerminalCloseCode(NSURLSessionWebSocketCloseCode code)
{
  return code == 4001 || code == 4002 || code == 4003 || code == 4004;
}

@interface WDAgentClient () <NSURLSessionWebSocketDelegate>
@property(nonatomic, copy) NSString *platformURL;
@property(nonatomic, copy) NSString *enrollmentCode;
@property(nonatomic, copy) NSString *installationID;
@property(nonatomic, copy) NSString *osVersion;
@property(nonatomic, copy) NSString *deviceModel;
@property(nonatomic, copy) NSString *locale;
@property(nonatomic, copy, nullable) NSString *wdaURL;
@property(nonatomic, copy, nullable) WDAgentEnrollCompletion completion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSOperationQueue *sessionQueue;
@property(nonatomic, strong, nullable) NSString *deviceToken;
@property(nonatomic, assign) NSInteger configVersion;
@property(nonatomic, assign) BOOL heartbeatStarted;
@property(nonatomic, assign) BOOL heartbeatStopped;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *webSocketTask;
@property(nonatomic, assign) BOOL wsRunning;
@property(nonatomic, assign) BOOL manualClose;
@property(nonatomic, assign) NSUInteger wsReconnectIndex;
@property(nonatomic, assign) NSUInteger enrollRetryIndex;
@property(nonatomic, assign) NSInteger msgCounter;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WDAgentClient

- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.whatsappai.wda.agent", DISPATCH_QUEUE_SERIAL);
    _sessionQueue = [[NSOperationQueue alloc] init];
    _sessionQueue.name = @"com.whatsappai.wda.agent.session";
    _sessionQueue.maxConcurrentOperationCount = 1;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:self
                                        delegateQueue:_sessionQueue];
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
  NSURLSessionWebSocketTask *task = nil;
  @synchronized(self) {
    self.wsRunning = NO;
    self.manualClose = YES;
    self.heartbeatStopped = YES;
    task = self.webSocketTask;
    self.webSocketTask = nil;
    self.completion = nil;
  }
  if (task != nil) {
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
  }
}

// MARK: - 注册

- (NSURL *)apiURLForPath:(NSString *)path
{
  NSString *base = self.platformURL;
  while ([base hasSuffix:@"/"]) {
    base = [base substringToIndex:base.length - 1];
  }
  return [NSURL URLWithString:[base stringByAppendingString:path]];
}

- (NSArray<NSString *> *)provisionedDeviceUDIDs
{
  // 普通 API 读不到真实 UDID；开发/Ad Hoc 签名包的 embedded.mobileprovision
  // 含 ProvisionedDevices，解析后上报平台（单设备 profile 时唯一）。
  NSString *path = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
  if (path.length == 0) {
    return @[];
  }
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data.length == 0) {
    return @[];
  }
  NSString *profile = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
  if (profile.length == 0) {
    return @[];
  }
  NSRange start = [profile rangeOfString:@"<plist"];
  NSRange end = [profile rangeOfString:@"</plist>"];
  if (start.location == NSNotFound || end.location == NSNotFound || end.location < start.location) {
    return @[];
  }
  NSRange plistRange = NSMakeRange(start.location, end.location + end.length - start.location);
  NSData *plistData = [[profile substringWithRange:plistRange] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:NULL];
  NSArray *devices = plist[@"ProvisionedDevices"];
  return [devices isKindOfClass:[NSArray class]] ? devices : @[];
}

- (void)enroll
{
  NSURL *url = [self apiURLForPath:@"/api/ios-agent/v1/enroll"];
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
    @"deviceUdids": [self provisionedDeviceUDIDs],
  };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = http ? http.statusCode : 0;
    // 网络错误 / 5xx / 429 视为瞬时失败，退避重试；4xx（除 429）为永久失败。
    if (error != nil || status >= 500 || status == 429) {
      [strongSelf scheduleEnrollRetry];
      return;
    }
    if (status / 100 != 2) {
      NSError *err = [NSError errorWithDomain:@"WDAgentClient"
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"enroll HTTP %ld", (long)status]}];
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
    @synchronized(strongSelf) {
      strongSelf.deviceToken = token;
      strongSelf.configVersion = configVersion;
    }
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

- (void)scheduleEnrollRetry
{
  NSArray<NSNumber *> *backoff = kBackoff();
  @synchronized(self) {
    if (self.completion == nil) {
      return;
    }
    NSUInteger index = MIN(self.enrollRetryIndex, backoff.count - 1);
    self.enrollRetryIndex += 1;
    NSTimeInterval delay = backoff[index].doubleValue;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
      WDAgentClient *strongSelf = weakSelf;
      if (!strongSelf || strongSelf.completion == nil) {
        return;
      }
      [strongSelf enroll];
    });
  }
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
  @synchronized(self) {
    if (self.heartbeatStarted) {
      return;
    }
    self.heartbeatStarted = YES;
    self.heartbeatStopped = NO;
  }
  [self scheduleNextHeartbeat];
}

- (void)scheduleNextHeartbeat
{
  @synchronized(self) {
    if (self.heartbeatStopped) {
      return;
    }
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeartbeatInterval * NSEC_PER_SEC)), self.queue, ^{
    WDAgentClient *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    @synchronized(strongSelf) {
      if (strongSelf.heartbeatStopped) {
        return;
      }
    }
    [strongSelf reportStatus];
    [strongSelf sendWSHeartbeat];
    [strongSelf scheduleNextHeartbeat];
  });
}

- (void)reportStatus
{
  NSString *token = nil;
  @synchronized(self) {
    token = self.deviceToken;
  }
  if (token.length == 0) {
    return;
  }
  NSURL *url = [self apiURLForPath:@"/api/ios-agent/v1/status"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
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
    NSInteger status = http ? http.statusCode : 0;
    if (error != nil) {
      NSLog(@"[WDAgent] 心跳上报网络错误: %@", error.localizedDescription);
      return;
    }
    if (status == 401) {
      NSLog(@"[WDAgent] 心跳 401：token 失效，停止 agent（需重新提供注册码启动）");
      [strongSelf stop];
      return;
    }
    if (status / 100 != 2) {
      NSLog(@"[WDAgent] 心跳上报失败 HTTP %ld", (long)status);
    }
  }];
  [task resume];
}

// MARK: - WSS 长连接

- (void)startWebSocket
{
  NSURLSessionWebSocketTask *task = nil;
  NSInteger configVersion = 0;
  @synchronized(self) {
    if (self.webSocketTask != nil || self.deviceToken.length == 0) {
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
    NSString *basePath = components.path ?: @"";
    if ([basePath hasSuffix:@"/"]) {
      basePath = [basePath substringToIndex:basePath.length - 1];
    }
    components.path = [basePath stringByAppendingString:@"/api/ios-agent/v1/ws"];
    NSURL *wsURL = components.URL;
    if (wsURL == nil) {
      return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:wsURL];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken] forHTTPHeaderField:@"Authorization"];

    task = [self.session webSocketTaskWithRequest:request];
    self.webSocketTask = task;
    self.wsRunning = YES;
    self.manualClose = NO;
    self.wsReconnectIndex = 0;
    configVersion = self.configVersion;
  }

  [task resume];
  [self sendFrameType:@"agent:hello" payload:@{
    @"app": @"WhatsAppDeviceAgent",
    @"os": self.osVersion ?: @"",
    @"model": self.deviceModel ?: @"",
    @"locale": self.locale ?: @"",
    @"configVersion": @(configVersion),
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
      BOOL shouldReconnect = NO;
      @synchronized(strongSelf) {
        if (strongSelf.wsRunning && !strongSelf.manualClose && strongSelf.webSocketTask == task) {
          strongSelf.webSocketTask = nil;
          shouldReconnect = YES;
        }
      }
      if (shouldReconnect) {
        [strongSelf reconnect];
      }
      return;
    }
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
      [strongSelf handleFrame:message.string];
    }
    @synchronized(strongSelf) {
      if (strongSelf.wsRunning) {
        [strongSelf receiveLoop:task];
      }
    }
  }];
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
             reason:(NSData *)reason
{
  BOOL shouldStop = NO;
  BOOL shouldReconnect = NO;
  @synchronized(self) {
    if (webSocketTask != self.webSocketTask) {
      return;
    }
    self.webSocketTask = nil;
    if (self.manualClose) {
      return;
    }
    if (!self.wsRunning) {
      return;
    }
    if (kIsTerminalCloseCode(closeCode)) {
      self.wsRunning = NO;
      self.manualClose = YES;
      shouldStop = YES;
    } else {
      shouldReconnect = YES;
    }
  }
  if (shouldStop) {
    NSLog(@"[WDAgent] WSS 被服务端永久关闭 code=%ld，停止重连", (long)closeCode);
  } else if (shouldReconnect) {
    [self reconnect];
  }
}

- (void)handleFrame:(nullable NSString *)text
{
  if (text.length == 0) {
    return;
  }
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSString *type = json[@"type"];
  NSLog(@"[WDAgent] WSS 收到帧: %@", type ?: @"(unknown)");
  if ([type isEqualToString:@"server:diagnostic_request"]) {
    NSString *requestID = json[@"payload"][@"requestId"];
    if (requestID.length > 0) {
      NSInteger configVersion = 0;
      @synchronized(self) {
        configVersion = self.configVersion;
      }
      [self sendFrameType:@"agent:status" payload:@{
        @"configVersion": @(configVersion),
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
  NSArray<NSNumber *> *backoff = kBackoff();
  @synchronized(self) {
    if (!self.wsRunning || self.manualClose || self.webSocketTask != nil) {
      return;
    }
    NSUInteger index = MIN(self.wsReconnectIndex, backoff.count - 1);
    self.wsReconnectIndex += 1;
    NSTimeInterval delay = backoff[index].doubleValue;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
      WDAgentClient *strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }
      [strongSelf startWebSocket];
    });
  }
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
  NSURLSessionWebSocketTask *task = nil;
  NSString *msgId = nil;
  @synchronized(self) {
    task = self.webSocketTask;
    if (task == nil) {
      return;
    }
    self.msgCounter += 1;
    msgId = [NSString stringWithFormat:@"%@:%ld", self.installationID, (long)self.msgCounter];
  }
  NSDictionary *envelope = @{
    @"v": @1,
    @"type": type,
    @"msgId": msgId,
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
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (addStatus != errSecSuccess) {
      NSLog(@"[WDAgent] 保存 token 到 Keychain 失败: %d", (int)addStatus);
    }
  } else if (status != errSecSuccess) {
    NSLog(@"[WDAgent] 更新 Keychain token 失败: %d", (int)status);
  }
}

@end
