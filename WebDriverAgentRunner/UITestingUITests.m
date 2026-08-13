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
#import "WDAgent.h"

@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>
@end

@implementation UITestingUITests

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
  // WhatsAppDeviceAgent：配置了 WDA_ENROLL_CODE 时在后台启动注册/心跳/WSS（未配置则保持 WDA 纯净）。
  // 注册码为敏感一次性凭证，日志只打印脱敏前缀，避免泄露到设备/系统日志。
  NSString *rawCode = NSProcessInfo.processInfo.environment[@"WDA_ENROLL_CODE"];
  NSString *maskedCode = rawCode.length > 4 ? [NSString stringWithFormat:@"%@***", [rawCode substringToIndex:4]] : @"(nil/短码)";
  NSLog(@"[WDAgent] setUp env: code=%@ platform=%@ count=%lu",
        maskedCode,
        NSProcessInfo.processInfo.environment[@"WDA_PLATFORM_URL"] ?: @"(nil)",
        (unsigned long)NSProcessInfo.processInfo.environment.count);
  if (NSProcessInfo.processInfo.environment[@"WDA_ENROLL_CODE"].length > 0) {
    [WDAgent.sharedAgent startWithEnvironment:NSProcessInfo.processInfo.environment];
  }
  [super setUp];
}

/**
 Never ending test used to start WebDriverAgent
 */
- (void)testRunner
{
  FBWebServer *webServer = [[FBWebServer alloc] init];
  webServer.delegate = self;
  [webServer startServing];
}

#pragma mark - FBWebServerDelegate

- (void)webServerDidRequestShutdown:(FBWebServer *)webServer
{
  [webServer stopServing];
}

@end
