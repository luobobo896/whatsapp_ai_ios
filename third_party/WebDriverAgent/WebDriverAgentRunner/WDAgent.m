#import "WDAgent.h"
#import "WDAgentClient.h"

#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>

static NSString *const kDefaultsInstallationID = @"wdagent.installationID";
static NSString *const kDefaultsDeviceID = @"wdagent.deviceId";
static NSString *const kDefaultsConfigVersion = @"wdagent.configVersion";

@interface WDAgent ()
@property(nonatomic, copy) NSString *platformURL;
@property(nonatomic, copy) NSString *enrollmentCode;
@property(nonatomic, copy) NSString *installationID;
@property(nonatomic, strong, nullable) WDAgentClient *client;
@property(nonatomic, assign) BOOL started;
@end

@implementation WDAgent

+ (instancetype)sharedAgent
{
  static WDAgent *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[WDAgent alloc] init];
  });
  return instance;
}

- (BOOL)startWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment
{
  if (self.started) {
    return YES;
  }
  NSString *code = [environment[@"WDA_ENROLL_CODE"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (code.length == 0) {
    return NO;
  }
  NSString *platform = [environment[@"WDA_PLATFORM_URL"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (platform.length == 0) {
    platform = @"https://hk.hsddns.com";
  }
  NSString *installation = [environment[@"WDA_INSTALLATION_ID"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (installation.length == 0) {
    installation = [self persistedInstallationID];
  }

  self.platformURL = platform;
  self.enrollmentCode = code;
  self.installationID = installation;
  self.started = YES;

  self.client = [[WDAgentClient alloc] init];
  __weak typeof(self) weakSelf = self;
  [self.client startWithPlatformURL:self.platformURL
                        enrollCode:self.enrollmentCode
                   installationID:self.installationID
                        osVersion:[UIDevice currentDevice].systemVersion
                     deviceModel:[UIDevice currentDevice].model
                          locale:[NSLocale currentLocale].localeIdentifier
                          wdaURL:[self wdaURL]
                      completion:^(NSString *_Nullable deviceID, NSInteger configVersion, NSError *_Nullable error) {
    if (error) {
      NSLog(@"[WDAgent] 注册失败: %@", error.localizedDescription);
      return;
    }
    WDAgent *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:deviceID forKey:kDefaultsDeviceID];
    [[NSUserDefaults standardUserDefaults] setInteger:configVersion forKey:kDefaultsConfigVersion];
    NSLog(@"[WDAgent] 注册成功 deviceId=%@ configVersion=%ld", deviceID, (long)configVersion);
  }];
  return YES;
}

- (void)stop
{
  [self.client stop];
}

// MARK: - 本地持久化

- (NSString *)persistedInstallationID
{
  NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kDefaultsInstallationID];
  if (saved.length > 0) {
    return saved;
  }
  NSString *newID = [[NSUUID UUID] UUIDString];
  [[NSUserDefaults standardUserDefaults] setObject:newID forKey:kDefaultsInstallationID];
  return newID;
}

// MARK: - WDA 直连地址（局域网 IP + WDA 端口）

- (nullable NSString *)wdaURL
{
  NSString *ip = [[self class] lanIPv4Address];
  if (ip.length == 0) {
    return nil;
  }
  NSString *port = NSProcessInfo.processInfo.environment[@"USE_PORT"];
  if (port.length == 0) {
    port = @"8100";
  }
  return [NSString stringWithFormat:@"http://%@:%@", ip, port];
}

+ (nullable NSString *)lanIPv4Address
{
  struct ifaddrs *ifaddr = NULL;
  if (getifaddrs(&ifaddr) != 0) {
    return nil;
  }
  NSString *en0IP = nil;
  NSString *cellularIP = nil;
  NSString *fallbackIP = nil;
  for (struct ifaddrs *ptr = ifaddr; ptr != NULL; ptr = ptr->ifa_next) {
    if (!ptr->ifa_addr || ptr->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    NSString *name = [NSString stringWithUTF8String:ptr->ifa_name];
    if (![name isEqualToString:@"en0"] && ![name isEqualToString:@"pdp_ip0"] && ![name hasPrefix:@"en"]) {
      continue;
    }
    char host[NI_MAXHOST] = {0};
    getnameinfo(ptr->ifa_addr, (socklen_t)ptr->ifa_addr->sa_len,
                host, sizeof(host), NULL, 0, NI_NUMERICHOST);
    NSString *ip = [NSString stringWithUTF8String:host];
    if (ip.length == 0 || [ip hasPrefix:@"169.254"] || [ip isEqualToString:@"127.0.0.1"]) {
      continue;
    }
    if ([name isEqualToString:@"en0"]) {
      if (!en0IP) en0IP = ip;
    } else if ([name isEqualToString:@"pdp_ip0"]) {
      if (!cellularIP) cellularIP = ip;
    } else {
      if (!fallbackIP) fallbackIP = ip;
    }
  }
  freeifaddrs(ifaddr);
  return en0IP ?: cellularIP ?: fallbackIP;
}

@end
