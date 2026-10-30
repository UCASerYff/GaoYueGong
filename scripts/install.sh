#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
TARGET="/Applications/搞月供.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Only the isolated regression harness may redirect installation or system commands.
if [[ -n "${GAO_INSTALL_FIXTURE_ROOT:-}" ]]; then
    FIXTURE=${GAO_INSTALL_FIXTURE_ROOT:A}
    [[ "$FIXTURE" == /private/tmp/gaoyuegong-install-test-*.noindex &&
       "$ROOT" == "$FIXTURE/project" && -f "$FIXTURE/.gaoyuegong-install-fixture" &&
       ! -L "$FIXTURE/Applications" ]] || { echo '拒绝非隔离测试路径'; exit 1; }
    TARGET="$FIXTURE/Applications/搞月供.app"
    LSREGISTER="$FIXTURE/mockbin/lsregister"
    export PATH="$FIXTURE/mockbin:$PATH"
fi
[[ ! -L "$TARGET" ]] || { echo '正式安装路径不能是符号链接'; exit 1; }
[[ ! -L "$ROOT/.install.noindex" && ! -L "$ROOT/Backups" ]] || { echo '安装暂存和回滚目录不能是符号链接'; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")

validate_bundle() {
    local app="$1" expected_version="$2" expected_build="$3" bundle expected_id
    codesign --verify --deep --strict "$app" || return 1
    for bundle in "$app" "$app/Contents/PlugIns/GaoYueGongWidgets.appex"; do
        expected_id=com.gaoseries.GaoYueGong
        [[ "$bundle" == "$app" ]] || expected_id+=.widgets
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == "$expected_id" &&
           "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" == "$expected_version" &&
           "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")" == "$expected_build" &&
           "$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == 5G96498KGJ ]] || return 1
        codesign -d --entitlements - "$bundle" 2>/dev/null | python3 -c '
import plistlib, sys
class UniqueDict(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise ValueError("Duplicate entitlement key")
        super().__setitem__(key, value)
try:
    raw = sys.stdin.buffer.read()
    if raw.startswith(b"[Dict]\n"):
        # Newer codesign displays a typed, indented dictionary instead of XML.
        blocks = raw.decode("utf-8").split("\n\t[Key] ")
        if blocks.pop(0) != "[Dict]":
            raise ValueError("Invalid entitlement dictionary")
        values = UniqueDict()
        for block in blocks:
            key, body = block.split("\n", 1)
            lines = body.splitlines()
            if not key or len(lines) < 2 or lines[0] != "\t[Value]" or any(not line.startswith("\t\t") for line in lines[1:]):
                raise ValueError("Invalid entitlement value")
            values[key] = lines[1:]
        array = values.get("com.apple.security.application-groups", [])
        prefix = "\t\t\t[String] "
        if array[:1] != ["\t\t[Array]"] or any(not line.startswith(prefix) for line in array[1:]):
            raise ValueError("Invalid entitlement group array")
        entitlements = {"com.apple.security.application-groups": [line[len(prefix):] for line in array[1:]]}
        if values.get("com.apple.security.app-sandbox") == ["\t\t[Bool] true"]:
            entitlements["com.apple.security.app-sandbox"] = True
    else:
        entitlements = plistlib.loads(raw, dict_type=UniqueDict)
    groups = entitlements.get("com.apple.security.application-groups")
    valid = (isinstance(groups, list) and all(isinstance(group, str) for group in groups)
             and "5G96498KGJ.com.gaoseries.GaoYueGong" in groups)
    if sys.argv[1].endswith(".widgets"):
        valid = valid and entitlements.get("com.apple.security.app-sandbox") is True
except Exception:
    valid = False
sys.exit(0 if valid else 1)
' "$expected_id" || return 1
    done
}

mkdir -p "$ROOT/.install.noindex"
STAGE=$(mktemp -d "$ROOT/.install.noindex/install.XXXXXX")
SOURCE="$ROOT/build.noindex/搞月供.app"
BACKUP=""; ARCHIVE=""; ARCHIVE_HASH=""; OLD_VERSION=""; OLD_BUILD=""
HELD=""; HAD_TARGET=0; RESTORE_NEEDED=0

record_receipt() {
    python3 - "$ROOT" "$BACKUP" "$TARGET" "$SOURCE" "$VERSION" "$NUMBER" \
        "$OLD_VERSION" "$OLD_BUILD" "$ARCHIVE" "$ARCHIVE_HASH" "$1" <<'PY'
import datetime, json, os, pathlib, sys
root, backup, target, source, version, build, old_version, old_build, archive, digest, status = sys.argv[1:]
folder = pathlib.Path(backup)
receipt = folder / 'receipt.json'
data = {'format': 1, 'updatedAt': datetime.datetime.now().astimezone().isoformat(),
    'status': status, 'target': target, 'source': source,
    'sourceVersion': version, 'sourceBuild': build,
    'targetVersionAfter': old_version if status in ['rolled-back', 'failed-before-replacement'] else version if status == 'installed' else None,
    'targetBuildAfter': old_build if status in ['rolled-back', 'failed-before-replacement'] else build if status == 'installed' else None,
    'previousVersion': old_version or None, 'previousBuild': old_build or None,
    'teamIdentifier': '5G96498KGJ', 'bundleIdentifier': 'com.gaoseries.GaoYueGong',
    'rollbackArchive': archive or None, 'rollbackSHA256': digest or None,
    'archiveExtractAndSignatureVerified': bool(archive),
    'rollbackDataPolicy': 'Program only; existing user data, settings and Keychain are never removed or restored by this installer.',
    'restoreProcedure': 'Verify archive SHA-256, extract into a .noindex directory, verify bundle signature/version, then replace the canonical target and register its host and widget extension. Never launch the archived app.'}
def atomic(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    os.replace(temporary, path)
atomic(receipt, data)
atomic(pathlib.Path(root) / 'Backups/install-latest.json',
       {'receipt': str(receipt), 'rollbackArchive': archive or None, 'rollbackSHA256': digest or None, 'target': target})
PY
}

finish() {
    local result_code=$?
    trap - EXIT
    if (( RESTORE_NEEDED )); then
        if (( HAD_TARGET )); then
            # Never remove the canonical app unless its verified predecessor is still available.
            if [[ -d "$HELD" ]] && validate_bundle "$HELD" "$OLD_VERSION" "$OLD_BUILD"; then
                rm -rf "$TARGET"
                if mv "$HELD" "$TARGET" && validate_bundle "$TARGET" "$OLD_VERSION" "$OLD_BUILD" &&
                   "$LSREGISTER" -f -R "$TARGET" && pluginkit -a "$TARGET/Contents/PlugIns/GaoYueGongWidgets.appex"; then
                    record_receipt rolled-back || true
                    echo '安装未完成，已恢复原程序；资料和压缩回滚归档保留。' >&2
                else
                    record_receipt rollback-needs-attention || true
                    echo "回滚需要检查；保留归档与收据：$BACKUP" >&2
                fi
            elif [[ ! -e "$HELD" ]] && validate_bundle "$TARGET" "$OLD_VERSION" "$OLD_BUILD"; then
                record_receipt failed-before-replacement || true
                echo '替换尚未发生，原程序与压缩回滚归档保留。' >&2
            else
                record_receipt rollback-needs-attention || true
                echo "未删除当前程序；回滚来源需要检查：$BACKUP" >&2
            fi
        else
            rm -rf "$TARGET"
            record_receipt failed-no-previous-app || true
        fi
        result_code=1
    fi
    rm -rf "$STAGE"
    [[ -z "$BACKUP" ]] || rm -rf "$BACKUP/verification"
    rmdir "$ROOT/.install.noindex" 2>/dev/null || true
    exit "$result_code"
}
trap finish EXIT

if [[ ! -d "$SOURCE" ]]; then
    (cd "$ROOT/dist"; shasum -a 256 -c "搞月供-$VERSION.zip.sha256")
    ditto -x -k "$ROOT/dist/搞月供-$VERSION.zip" "$STAGE"
    SOURCE="$STAGE/搞月供.app"
fi
validate_bundle "$SOURCE" "$VERSION" "$NUMBER" || { echo '新程序签名、标识或版本不匹配；未改动正式程序'; exit 1; }
if [[ "$SOURCE" != "$STAGE/搞月供.app" ]]; then
    ditto "$SOURCE" "$STAGE/搞月供.app"
fi
validate_bundle "$STAGE/搞月供.app" "$VERSION" "$NUMBER" || exit 1
if pgrep -f '^'"$TARGET"'/Contents/MacOS/GaoYueGong' >/dev/null; then
    echo '请先退出当前应用'; exit 1
else
    PROCESS_RESULT=$?
    [[ "$PROCESS_RESULT" == 1 ]] || { echo '无法核验应用进程，未改动正式程序'; exit 1; }
fi

mkdir -p "$ROOT/Backups"
BACKUP="$ROOT/Backups/Install-$(date +%Y%m%d-%H%M%S)-$$.noindex"
mkdir -m 700 "$BACKUP"
HELD="$BACKUP/previous/搞月供.app"
if [[ -e "$TARGET" ]]; then
    [[ -d "$TARGET" ]] || { echo '正式路径不是应用目录'; exit 1; }
    OLD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")
    OLD_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist")
    validate_bundle "$TARGET" "$OLD_VERSION" "$OLD_BUILD" || exit 1
    ARCHIVE="$BACKUP/搞月供-$OLD_VERSION-$OLD_BUILD.zip"
    ditto -c -k --keepParent "$TARGET" "$ARCHIVE"
    python3 - "$ARCHIVE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    if archive.testzip() is not None:
        raise SystemExit('回滚归档校验失败')
PY
    ARCHIVE_HASH=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
    (cd "$BACKUP"; shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
    mkdir -p "$BACKUP/verification" "$BACKUP/previous"
    ditto -x -k "$ARCHIVE" "$BACKUP/verification"
    validate_bundle "$BACKUP/verification/搞月供.app" "$OLD_VERSION" "$OLD_BUILD" || exit 1
    rm -rf "$BACKUP/verification"
    record_receipt rollback-ready || exit 1
    HAD_TARGET=1
    RESTORE_NEEDED=1
    mv "$TARGET" "$HELD"
else
    record_receipt ready-no-previous-app || exit 1
    RESTORE_NEEDED=1
fi

# All failures after replacement begins, including widget registration, run the EXIT rollback.
ditto "$STAGE/搞月供.app" "$TARGET"
validate_bundle "$TARGET" "$VERSION" "$NUMBER" || exit 1
"$LSREGISTER" -f -R "$TARGET"
pluginkit -a "$TARGET/Contents/PlugIns/GaoYueGongWidgets.appex"
record_receipt installed || exit 1
RESTORE_NEEDED=0
rm -rf "$BACKUP/previous"
killall -TERM GaoYueGongWidgets 2>/dev/null || true
echo "Installed $TARGET"
echo "Verified rollback receipt: $BACKUP/receipt.json"
