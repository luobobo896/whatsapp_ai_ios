/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <WebDriverAgentLib/FBDebugLogDelegateDecorator.h>
#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBFailureProofTestCase.h>
#import <WebDriverAgentLib/FBWebServer.h>
#import <WebDriverAgentLib/XCTestCase.h>

#import "WDARunnerPages.h"

// SwiftUI 首页（whatsapp_ai_ios 首页文件挪入，见 WDAHomePage.swift）
UIViewController *WDAHomePageHostMakeViewController(void (^onScan)(void), void (^onManualInput)(void));
// SwiftUI 注册页、设备状态页与 Agent 运行时（见 WDAAgentViews.swift / WDAAgentRuntime.swift）。
void WDAAgentApplyEnrollmentCode(NSString *value);
BOOL WDAAgentRestoreEnrollment(void);
BOOL WDAAgentHasEnrollmentPrefill(void);
UIViewController *WDARegistrationHostMakeViewController(void (^onScan)(void),
                                                         void (^onHome)(void),
                                                         void (^onRegistered)(void));
UIViewController *WDADeviceStatusHostMakeViewController(void (^onReenroll)(void));

@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>
@end

@implementation UITestingUITests {
  UIWindow *_runnerWindow;
  WDAScanViewController *_scanViewController;
  UIViewController *_registrationViewController;
  UIViewController *_deviceStatusViewController;
  UIViewController *_homeViewController;
}

+ (void)setUp
{
  [FBDebugLogDelegateDecorator decorateXCTestLogger];
  [FBConfiguration disableRemoteQueryEvaluation];
  [FBConfiguration configureDefaultKeyboardPreferences];
  [FBConfiguration disableApplicationUIInterruptionsHandling];
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREEN_RECORDINGS"]) {
    [FBConfiguration enableScreenRecordings];
  } else {
    [FBConfiguration disableScreenRecordings];
  }
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREENSHOTS"]) {
    [FBConfiguration enableScreenshots];
  } else {
    [FBConfiguration disableScreenshots];
  }
  [super setUp];
}

/**
 Never ending test used to start WebDriverAgent
 */
- (void)testRunner
{
  // 诊断：确认 USB 真机 UDID 是否已注入到 Runner 进程环境变量。
  fprintf(stderr, "[ENV-DIAG] WDA_DEVICE_UDID=%s\n", getenv("WDA_DEVICE_UDID") ?: "(nil)");

  // 启动 WDA 服务的同时展示设备注册首页。
  [self setupPagesUI];

  FBWebServer *webServer = [[FBWebServer alloc] init];
  webServer.delegate = self;
  [webServer startServing];
}

#pragma mark - FBWebServerDelegate

- (void)webServerDidRequestShutdown:(FBWebServer *)webServer
{
  [webServer stopServing];
}

#pragma mark - 设备注册页面

- (void)setupPagesUI
{
  if (_runnerWindow != nil) { return; }

  UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  window.backgroundColor = UIColor.systemBackgroundColor;
  _runnerWindow = window;

  WDAScanViewController *scan = [[WDAScanViewController alloc] init];
  _scanViewController = scan;
  __weak typeof(self) weakSelf = self;
  scan.onManualInput = ^{
    [weakSelf showRegistrationPageWithCode:nil];
  };
  scan.onScannedCode = ^(NSString *code) {
    [weakSelf showRegistrationPageWithCode:code];
  };

  _homeViewController = WDAHomePageHostMakeViewController(^{
    [weakSelf showScanPage];
  }, ^{
    [weakSelf showRegistrationPageWithCode:nil];
  });

  scan.onShowHome = ^{
    [weakSelf showHomePage];
  };

  // 已注册设备直接恢复心跳/WSS 并进入设备页；否则展示注册引导首页。
  if (WDAAgentRestoreEnrollment()) {
    window.rootViewController = [self makeDeviceStatusViewController];
  } else if (WDAAgentHasEnrollmentPrefill()) {
    window.rootViewController = [self makeRegistrationViewController];
  } else {
    window.rootViewController = _homeViewController;
  }
  [window makeKeyAndVisible];
}

- (void)showScanPage
{
  _runnerWindow.rootViewController = _scanViewController;
}

- (void)showRegistrationPageWithCode:(nullable NSString *)code
{
  WDAAgentApplyEnrollmentCode(code ?: @"");
  _runnerWindow.rootViewController = [self makeRegistrationViewController];
}

- (UIViewController *)makeRegistrationViewController
{
  __weak typeof(self) weakSelf = self;
  _registrationViewController = WDARegistrationHostMakeViewController(^{
    [weakSelf showScanPage];
  }, ^{
    [weakSelf showHomePage];
  }, ^{
    [weakSelf showDeviceStatusPage];
  });
  return _registrationViewController;
}

- (void)showHomePage
{
  _runnerWindow.rootViewController = _homeViewController;
}

- (UIViewController *)makeDeviceStatusViewController
{
  __weak typeof(self) weakSelf = self;
  _deviceStatusViewController = WDADeviceStatusHostMakeViewController(^{
    [weakSelf showHomePage];
  });
  return _deviceStatusViewController;
}

- (void)showDeviceStatusPage
{
  _runnerWindow.rootViewController = [self makeDeviceStatusViewController];
}

@end
