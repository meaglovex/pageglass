#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scripts/build.sh
qa_app="$PWD/qa-output/Pageglass08QA.app"
mkdir -p "$qa_app"
ditto dist/Pageglass.app "$qa_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.pageglass.qa08' "$qa_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :PageglassRequiresIsolatedProfile bool true' "$qa_app/Contents/Info.plist"
codesign --force --sign - "$qa_app"
print "$qa_app"
print 'Launch with --qa-profile /private/tmp/pageglass-qa08/<profile>; no-argument launches are refused.'
