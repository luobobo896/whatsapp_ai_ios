/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ViewController.h"

static NSString *const WDALauncherServiceType = @"_wda-launcher._tcp.";

@interface ViewController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (weak, nonatomic) IBOutlet UILabel *orentationLabel;
@property (weak, nonatomic) IBOutlet UIButton *button;
@property (nonatomic, strong) UIButton *startWDAButton;
@property (nonatomic, strong) UILabel *wdaStatusLabel;
@property (nonatomic, strong) NSNetServiceBrowser *wdaLauncherBrowser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *wdaLauncherServices;
@property (nonatomic, strong) NSMutableArray<NSURL *> *wdaLauncherURLs;
@property (nonatomic, strong) NSMutableSet<NSString *> *wdaAttemptedURLStrings;
@property (nonatomic, strong) NSURLSessionDataTask *wdaStartTask;
@property (nonatomic, assign) NSUInteger wdaDiscoveryGeneration;
@property (nonatomic, assign) BOOL wdaStartRequestInFlight;
@end

@implementation ViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  UIAccessibilityCustomAction *action1 =
  [[UIAccessibilityCustomAction alloc] initWithName:@"Custom Action 1"
                                             target:self
                                           selector:@selector(handleCustomAction:)];
  UIAccessibilityCustomAction *action2 =
  [[UIAccessibilityCustomAction alloc] initWithName:@"Custom Action 2"
                                             target:self
                                           selector:@selector(handleCustomAction:)];
  self.button.accessibilityCustomActions = @[action1, action2];

  self.startWDAButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.startWDAButton.translatesAutoresizingMaskIntoConstraints = NO;
  self.startWDAButton.accessibilityIdentifier = @"startWebDriverAgentButton";
  [self.startWDAButton setTitle:@"启动 WebDriverAgent" forState:UIControlStateNormal];
  [self.startWDAButton addTarget:self
                          action:@selector(startWebDriverAgent:)
                forControlEvents:UIControlEventTouchUpInside];

  self.wdaStatusLabel = [UILabel new];
  self.wdaStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.wdaStatusLabel.accessibilityIdentifier = @"webDriverAgentStatus";
  self.wdaStatusLabel.font = [UIFont systemFontOfSize:13];
  self.wdaStatusLabel.text = @"未启动";
  self.wdaStatusLabel.textAlignment = NSTextAlignmentCenter;
  self.wdaStatusLabel.textColor = UIColor.secondaryLabelColor;

  [self.view addSubview:self.startWDAButton];
  [self.view addSubview:self.wdaStatusLabel];
  [NSLayoutConstraint activateConstraints:@[
    [self.startWDAButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [self.startWDAButton.bottomAnchor constraintEqualToAnchor:self.wdaStatusLabel.topAnchor constant:-6],
    [self.wdaStatusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [self.wdaStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
    [self.wdaStatusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20],
    [self.wdaStatusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
  ]];
}

- (void)startWebDriverAgent:(UIButton *)sender
{
  [self stopWDALauncherDiscovery];
  sender.enabled = NO;
  self.wdaStatusLabel.text = @"正在动态查找 Mac 启动服务...";
  self.wdaLauncherServices = [NSMutableArray array];
  self.wdaLauncherURLs = [NSMutableArray array];
  self.wdaAttemptedURLStrings = [NSMutableSet set];

  NSNetServiceBrowser *browser = [NSNetServiceBrowser new];
  browser.delegate = self;
  browser.includesPeerToPeer = YES;
  self.wdaLauncherBrowser = browser;
  NSUInteger generation = ++self.wdaDiscoveryGeneration;
  [browser searchForServicesOfType:WDALauncherServiceType inDomain:@"local."];

  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf.wdaDiscoveryGeneration != generation) {
      return;
    }
    BOOL foundService = strongSelf.wdaAttemptedURLStrings.count > 0 || strongSelf.wdaLauncherURLs.count > 0;
    [strongSelf stopWDALauncherDiscovery];
    strongSelf.wdaStatusLabel.text = foundService
      ? @"启动失败：已发现 Mac，但无法连接启动服务"
      : @"启动失败：未发现 Mac，请确认启动服务正在运行";
    sender.enabled = YES;
  });
}

- (void)requestNextDiscoveredLauncher:(UIButton *)sender
{
  if (self.wdaStartRequestInFlight) {
    return;
  }

  NSURL *url = nil;
  for (NSURL *candidate in self.wdaLauncherURLs) {
    if (![self.wdaAttemptedURLStrings containsObject:candidate.absoluteString]) {
      url = candidate;
      break;
    }
  }
  if (!url) {
    return;
  }

  [self.wdaAttemptedURLStrings addObject:url.absoluteString];
  self.wdaStartRequestInFlight = YES;
  self.wdaStatusLabel.text = @"已发现 Mac，正在请求启动 WDA...";
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 5;
  NSUInteger generation = self.wdaDiscoveryGeneration;
  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf || strongSelf.wdaDiscoveryGeneration != generation) {
        return;
      }
      strongSelf.wdaStartRequestInFlight = NO;
      strongSelf.wdaStartTask = nil;
      if (!error && httpResponse.statusCode == 202) {
        [strongSelf stopWDALauncherDiscovery];
        strongSelf.wdaStatusLabel.text = @"启动脚本已执行，WDA 正在启动";
        return;
      }
      [strongSelf requestNextDiscoveredLauncher:sender];
    });
  }];
  self.wdaStartTask = task;
  [task resume];
}

- (void)stopWDALauncherDiscovery
{
  self.wdaDiscoveryGeneration += 1;
  [self.wdaStartTask cancel];
  self.wdaStartTask = nil;
  self.wdaStartRequestInFlight = NO;
  for (NSNetService *service in self.wdaLauncherServices) {
    service.delegate = nil;
    [service stop];
  }
  [self.wdaLauncherBrowser stop];
  self.wdaLauncherBrowser.delegate = nil;
  self.wdaLauncherBrowser = nil;
}

#pragma mark - WDA Launcher Bonjour Discovery

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing
{
  service.delegate = self;
  service.includesPeerToPeer = YES;
  [self.wdaLauncherServices addObject:service];
  [service resolveWithTimeout:5];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
  UIButton *sender = self.startWDAButton;
  [self stopWDALauncherDiscovery];
  self.wdaStatusLabel.text = @"启动失败：无法搜索本地网络中的 Mac";
  sender.enabled = YES;
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
  NSString *host = service.hostName;
  if (host.length == 0 || service.port <= 0) {
    return;
  }
  NSURLComponents *components = [NSURLComponents new];
  components.scheme = @"http";
  components.host = host;
  components.port = @(service.port);
  components.path = @"/start";
  NSURL *url = components.URL;
  if (!url || [self.wdaLauncherURLs containsObject:url]) {
    return;
  }
  [self.wdaLauncherURLs addObject:url];
  [self requestNextDiscoveredLauncher:self.startWDAButton];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
  service.delegate = nil;
  [self.wdaLauncherServices removeObject:service];
}

- (BOOL)handleCustomAction:(UIAccessibilityCustomAction *)action
{
  // Custom action handler - just return YES to indicate success
  return YES;
}

- (IBAction)deadlockApp:(id)sender
{
  dispatch_sync(dispatch_get_main_queue(), ^{
    // This will never execute
  });
}

- (IBAction)didTapButton:(UIButton *)button
{
  button.selected = !button.selected;
}

- (IBAction)goToDeepHierarchy:(id)sender
{
  // Plain UIViews with fixed frames only - no Auto Layout constraints and no
  // specialized subclasses (e.g. UITextView) that carry their own layout/text
  // engines, which can make a deep nested chain pathologically expensive to
  // lay out. This page exists purely as a fixture for exercising element
  // lookups (e.g. class chain locators) against a deep accessibility tree.
  UIViewController *deepHierarchyViewController = [UIViewController new];
  deepHierarchyViewController.view.backgroundColor = UIColor.whiteColor;
  deepHierarchyViewController.view.accessibilityIdentifier = @"DeepHierarchyPage";

  NSInteger depth = 70;
  // A plain UILabel sibling, not part of the nested chain below, so the
  // fixture stays recognizable to a human glancing at the simulator instead
  // of showing a blank white screen.
  UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, CGRectGetWidth(UIScreen.mainScreen.bounds) - 40, 60)];
  titleLabel.text = [NSString stringWithFormat:@"Deep Hierarchy\n%ld nested elements", (long)depth];
  titleLabel.numberOfLines = 2;
  titleLabel.textAlignment = NSTextAlignmentCenter;
  titleLabel.font = [UIFont systemFontOfSize:20];
  [deepHierarchyViewController.view addSubview:titleLabel];

  UIView *parent = deepHierarchyViewController.view;
  for (NSInteger i = 0; i < depth; i++) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    view.accessibilityIdentifier = [NSString stringWithFormat:@"view_%ld", (long)i];
    view.accessibilityLabel = [NSString stringWithFormat:@"View %ld", (long)i];
    [parent addSubview:view];
    parent = view;
  }

  [self.navigationController pushViewController:deepHierarchyViewController animated:NO];
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  [self updateOrentationLabel];
}

#if !TARGET_OS_TV
- (void)updateOrentationLabel
{
  NSString *orientation = nil;
  switch (UIDevice.currentDevice.orientation) {
    case UIInterfaceOrientationPortrait:
      orientation = @"Portrait";
      break;
    case UIInterfaceOrientationPortraitUpsideDown:
      orientation = @"PortraitUpsideDown";
      break;
    case UIInterfaceOrientationLandscapeLeft:
      orientation = @"LandscapeLeft";
      break;
    case UIInterfaceOrientationLandscapeRight:
      orientation = @"LandscapeRight";
      break;
    case UIDeviceOrientationFaceUp:
      orientation = @"FaceUp";
      break;
    case UIDeviceOrientationFaceDown:
      orientation = @"FaceDown";
      break;
    case UIInterfaceOrientationUnknown:
      orientation = @"Unknown";
      break;
  }
  self.orentationLabel.text = orientation;
}
#endif

@end
