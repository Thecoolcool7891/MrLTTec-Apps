#!/usr/bin/env bash
# Builds one app folder into an unsigned IPA, publishes it as a GitHub Release,
# and adds it to source.json. Runs on the GitHub Actions macOS runner.
set -euo pipefail

APP="$1"
DIR="apps/$APP"
meta() { python3 -c "import json,sys; print(json.load(open('$DIR/app.json'))[sys.argv[1]])" "$1"; }

SCHEME="$(meta scheme)"
NAME="$(meta name)"
BUILD="$GITHUB_RUN_NUMBER"
VERSION="$(meta baseVersion).$BUILD"
IPA="$SCHEME-$VERSION.ipa"

echo "::group::Build $NAME $VERSION"
pushd "$DIR" >/dev/null
xcodegen generate
xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
rm -rf Payload && mkdir Payload
cp -R "build/Build/Products/Release-iphoneos/$SCHEME.app" Payload/
zip -qry "$IPA" Payload
popd >/dev/null
echo "::endgroup::"

TAG="$APP-v$VERSION"
NOTES="$(git log -1 --pretty=%s -- "$DIR")"
[ -z "$NOTES" ] && NOTES="Build $BUILD"

gh release create "$TAG" "$DIR/$IPA" --title "$NAME $VERSION" --notes "$NOTES"
URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/$IPA"

# source.json is updated in a later step, on top of the newest main (so parallel builds never collide).
mkdir -p "$RUNNER_TEMP/updates"
printf '%q ' "$APP" "$VERSION" "$BUILD" "$PWD/$DIR/$IPA" "$URL" "$NOTES" > "$RUNNER_TEMP/updates/$APP.args"
