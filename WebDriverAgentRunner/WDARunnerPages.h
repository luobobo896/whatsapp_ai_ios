/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 扫码页：真机摄像头实时扫码，从 whatsapp_ai_ios QRScannerView 移植。
@interface WDAScanViewController : UIViewController
/// 点「手动输入注册码」时回调。
@property (nonatomic, copy, nullable) void (^onManualInput)(void);
/// 点「首页」时回调。
@property (nonatomic, copy, nullable) void (^onShowHome)(void);
/// 扫到二维码后回调注册码。
@property (nonatomic, copy, nullable) void (^onScannedCode)(NSString * _Nullable code);
@end

NS_ASSUME_NONNULL_END
