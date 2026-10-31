#!/usr/bin/env bash
# 基础检查 3/6 · Gradle Wrapper 完整性
#
# Wrapper 是整条构建链的信任根：gradle-wrapper.jar 被换掉 = 谁都能在 CI 里跑任意代码。
# jar 是否为 Gradle 官方发布的那一个，由 gradle/actions/wrapper-validation 对照官方校验和判断；
# 本脚本补三件它不管的事：
#   1. jar / 脚本齐全，且 jar 的 SHA-256 与这里钉死的值一致（升级 Gradle 时同步改）
#   2. distributionUrl 走 https、版本固定、不指向 RC/SNAPSHOT
#   3. 配了 distributionSha256Sum（Gradle 下载发行包时会校验完整性）
set -euo pipefail

cd "$(dirname "$0")/../.."   # → 仓库根

WRAPPER_JAR="vm/gradle/wrapper/gradle-wrapper.jar"
PROPS="vm/gradle/wrapper/gradle-wrapper.properties"
EXPECTED_VERSION="8.9"
EXPECTED_JAR_SHA256="498495120a03b9a6ab5d155f5de3c8f0d986a449153702fb80fc80e134484f17"

fail() { echo "[FAIL] $*"; exit 1; }
ok()   { echo "[OK] $*"; }

for f in "$WRAPPER_JAR" "$PROPS" vm/gradlew vm/gradlew.bat; do
    [ -f "$f" ] || fail "缺少文件：$f"
done

# CI 里直接 `./gradlew ...`，脚本丢了可执行位就会在 checkout 后 Permission denied。
[ -x vm/gradlew ] || fail "vm/gradlew 没有可执行位（git 索引里应为 100755）"
ok "gradlew / gradlew.bat 齐全且可执行"

actual_jar_sha="$(sha256sum "$WRAPPER_JAR" | awk '{print $1}')"
if [ "$actual_jar_sha" != "$EXPECTED_JAR_SHA256" ]; then
    fail "gradle-wrapper.jar 与钉死值不一致：$actual_jar_sha
       期望：$EXPECTED_JAR_SHA256
       升级 Gradle 时请同步更新本脚本的 EXPECTED_VERSION / EXPECTED_JAR_SHA256"
fi
ok "gradle-wrapper.jar SHA-256 与钉死值一致"

url="$(grep -E '^distributionUrl=' "$PROPS" | cut -d= -f2- | sed 's/\\//g')"
case "$url" in
    https://*) ;;
    *) fail "distributionUrl 必须走 https：$url" ;;
esac

version=""
if [[ "$url" =~ /gradle-([0-9]+(\.[0-9]+)+)-bin\.zip$ ]]; then
    version="${BASH_REMATCH[1]}"
fi
[ -n "$version" ] || fail "distributionUrl 解析不出固定版本（应为 .../gradle-<版本>-bin.zip）：$url"
[ "$version" = "$EXPECTED_VERSION" ] ||
    fail "Gradle 版本应为 $EXPECTED_VERSION，实际 $version（升级请同步改本脚本）"
ok "distributionUrl 固定为 gradle-$EXPECTED_VERSION（https）"

grep -q '^validateDistributionUrl=true$' "$PROPS" ||
    fail "validateDistributionUrl 应为 true（Gradle 8.x 的发行包 URL 校验）"

sum="$(grep -E '^distributionSha256Sum=' "$PROPS" | cut -d= -f2- || true)"
[ -n "${sum:-}" ] || fail "缺少 distributionSha256Sum：发行包完整性不会被校验"
printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' ||
    fail "distributionSha256Sum 不是 64 位小写十六进制：$sum"
ok "distributionSha256Sum 已配置"

echo "[OK] Gradle Wrapper 校验通过"
