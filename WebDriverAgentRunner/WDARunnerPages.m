/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "WDARunnerPages.h"

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - WDAScanViewController（扫码页）

@interface WDAScanViewController () <AVCaptureMetadataOutputObjectsDelegate>
@end

@implementation WDAScanViewController {
  AVCaptureSession *_session;
  BOOL _hasScanned;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;
  [self setupCamera];
  [self addHomeButton];
  [self addManualInputButton];
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  // 预览层跟随页面尺寸（旋转/分屏等场景）。
  for (CALayer *layer in self.view.layer.sublayers) {
    if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class]) {
      layer.frame = self.view.bounds;
    }
  }
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  _hasScanned = NO;
  if (_session != nil && !_session.isRunning) {
    [_session startRunning];
  }
}

- (void)viewDidDisappear:(BOOL)animated
{
  [super viewDidDisappear:animated];
  [_session stopRunning];
}

#pragma mark - 摄像头实时扫码（移植自 whatsapp_ai_ios QRScannerView）

- (void)setupCamera
{
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
    case AVAuthorizationStatusAuthorized:
      [self startCaptureSession];
      break;
    case AVAuthorizationStatusNotDetermined: {
      __weak typeof(self) weakSelf = self;
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        __strong typeof(self) strongSelf = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (strongSelf == nil) { return; }
          if (granted) {
            [strongSelf startCaptureSession];
          } else {
            [strongSelf showPermissionDenied];
          }
        });
      }];
      break;
    }
    case AVAuthorizationStatusDenied:
    case AVAuthorizationStatusRestricted:
    default:
      [self showPermissionDenied];
      break;
  }
}

- (void)startCaptureSession
{
  AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
  if (device == nil || input == nil) {
    [self showPermissionDenied];
    return;
  }
  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  if (![session canAddInput:input]) { return; }
  [session addInput:input];

  AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
  if (![session canAddOutput:output]) { return; }
  [session addOutput:output];
  [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
  if ([output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
    output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
  }

  AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
  preview.frame = self.view.bounds;
  preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
  [self.view.layer insertSublayer:preview atIndex:0];
  _session = session;
  [session startRunning];
}

- (void)showPermissionDenied
{
  UILabel *label = [UILabel new];
  label.text = NSLocalizedString(@"相机权限被拒绝，请在「设置」中允许本 App 访问相机后重试。", @"");
  label.textColor = UIColor.whiteColor;
  label.font = [UIFont systemFontOfSize:16];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
    [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
  ]];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection
{
  if (_hasScanned) { return; }
  AVMetadataMachineReadableCodeObject *obj = metadataObjects.firstObject;
  if (![obj isKindOfClass:AVMetadataMachineReadableCodeObject.class] || obj.stringValue.length == 0) {
    return;
  }
  _hasScanned = YES;
  [_session stopRunning];
  if (self.onScannedCode) { self.onScannedCode(obj.stringValue); }
}

#pragma mark - 首页入口

- (void)addHomeButton
{
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
  config.image = [UIImage systemImageNamed:@"house.fill"];
  config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  config.baseForegroundColor = UIColor.whiteColor;
  config.background.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
  config.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
  button.configuration = config;
  button.accessibilityIdentifier = @"homeButton";
  button.accessibilityLabel = NSLocalizedString(@"首页", @"");
  [button addTarget:self action:@selector(homeTapped) forControlEvents:UIControlEventTouchUpInside];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:button];
  [NSLayoutConstraint activateConstraints:@[
    [button.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
    [button.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
    [button.widthAnchor constraintEqualToConstant:44],
    [button.heightAnchor constraintEqualToConstant:44],
  ]];
}

- (void)homeTapped
{
  if (self.onShowHome) { self.onShowHome(); }
}

#pragma mark - 手动输入注册码入口

- (void)addManualInputButton
{
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
  config.title = NSLocalizedString(@"手动输入注册码", @"");
  config.image = [UIImage systemImageNamed:@"keyboard"];
  config.imagePadding = 8;
  config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
  config.contentInsets = NSDirectionalEdgeInsetsMake(12, 20, 12, 20);
  button.configuration = config;
  button.accessibilityIdentifier = @"manualInputButton";
  [button addTarget:self action:@selector(manualInputTapped) forControlEvents:UIControlEventTouchUpInside];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:button];
  [NSLayoutConstraint activateConstraints:@[
    [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-32],
  ]];
}

- (void)manualInputTapped
{
  if (self.onManualInput) { self.onManualInput(); }
}

@end
NS_ASSUME_NONNULL_END
