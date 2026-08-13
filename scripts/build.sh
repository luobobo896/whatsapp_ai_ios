#!/bin/bash
#
# Copyright (c) 2015-present, Facebook, Inc.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.
#

set -ex

function define_xc_macros() {
  XC_MACROS="CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO"

  case "$TARGET" in
    "lib" ) XC_TARGET="WebDriverAgentLib";;
    "runner" ) XC_TARGET="WebDriverAgentRunner";;
    *) echo "Unknown TARGET"; exit 1 ;;
  esac

  case "${DEST:-}" in
    "iphone" ) XC_DESTINATION="platform=iOS Simulator,name=`echo $IPHONE_MODEL | tr -d "'"`,OS=$IOS_VERSION";;
    "ipad" ) XC_DESTINATION="platform=iOS Simulator,name=`echo $IPAD_MODEL | tr -d "'"`,OS=$IOS_VERSION";;
    "generic" ) XC_DESTINATION="generic/platform=iOS";;
  esac

  case "$ACTION" in
    "build" ) XC_ACTION="build";;
    "analyze" )
      XC_ACTION="analyze"
      XC_MACROS="${XC_MACROS} CLANG_ANALYZER_OUTPUT=plist-html CLANG_ANALYZER_OUTPUT_DIR=\"$(pwd)/clang\""
    ;;
  esac

  case "$SDK" in
    "sim" ) XC_SDK="iphonesimulator";;
    "device" ) XC_SDK="iphoneos";;
    *) echo "Unknown SDK"; exit 1 ;;
  esac

  case "${CODE_SIGN:-}" in
    "no" ) XC_MACROS="${XC_MACROS} CODE_SIGNING_ALLOWED=NO";;
  esac
}

function analyze() {
  xcbuild
  if [[ -z $(find clang -name "*.html") ]]; then
    echo "Static Analyzer found no issues"
  else
    echo "Static Analyzer found some issues"
    exit 1
  fi
}

function xcbuild() {
    destination=""
    output_command=cat
    if [ $(which xcpretty) ] ; then
        output_command=xcpretty
    fi

    XC_BUILD_ARGS=(-project "WebDriverAgent.xcodeproj")
    XC_BUILD_ARGS+=(-scheme "$XC_TARGET")
    XC_BUILD_ARGS+=(-sdk "$XC_SDK")
    XC_BUILD_ARGS+=($XC_ACTION)
    if [[ -n "$XC_DESTINATION" ]]; then
      XC_BUILD_ARGS+=(-destination "${XC_DESTINATION}")
    fi
    if [[ -n "$DERIVED_DATA_PATH" ]]; then
      XC_BUILD_ARGS+=(-derivedDataPath ${DERIVED_DATA_PATH})
    fi
    XC_BUILD_ARGS+=($XC_MACROS $EXTRA_XC_ARGS)

    xcodebuild "${XC_BUILD_ARGS[@]}" | $output_command && exit ${PIPESTATUS[0]}

}

define_xc_macros
case "$ACTION" in
  "analyze" ) analyze ;;
  *) xcbuild ;;
esac
