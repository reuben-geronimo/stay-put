#!/bin/sh
set -e

# get version tag or commit id
VERSION=$(git describe HEAD)

# set app version
agvtool new-version ${VERSION:1}

# build
xcodebuild -quiet -project StayPut.xcodeproj -configuration Release -target StayPut

# clean dist
rm -rf dist && mkdir dist

# make dmg from app
hdiutil create -fs HFS+ -srcfolder build/Release/StayPut.app -volname StayPut dist/StayPut.dmg

# clean build
rm -r build