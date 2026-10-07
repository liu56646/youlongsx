# 真机调试循环：构建 → 安装 → 启动实例 → 收日志
#
# 用法：
#   .\dev_run.ps1              # 用 Android 11 镜像，等 15 秒
#   .\dev_run.ps1 -Tag p9_arm64 -WaitSeconds 25
#   .\dev_run.ps1 -SkipBuild
#
param(
    [string]$Tag = "p11_arm64",
    [int]$WaitsSeconds = 15,
    [switch]$SkipBuild
)

# 调试脚手架：adb 会往 stderr 写进度/提示（如 "1 file pushed"），
# 在 $ErrorActionPreference="Stop" 下会被 PowerShell 当成致命错误中断脚本。
# 这里刻意不设 Stop，让每个步骤各自输出、整体跑完。
$ErrorActionPreference = "Continue"

$adb = "C:\Users\liu\AppData\Local\Android\Sdk\platform-tools\adb.exe"
$gradle = "C:\Users\liu\.gradle\wrapper\dists\gradle-8.9-bin\90cnw93cvbtalezasaz0blq0a\gradle-8.9\bin\gradle.bat"
$repo = Split-Path -Parent $PSScriptRoot          # vm/
$apk = Join-Path $repo "app\build\outputs\apk\debug\app-debug.apk"

if (-not $SkipBuild) {
    Write-Host "=== 构建 ===" -ForegroundColor Cyan
    & $gradle -p $repo :app:assembleDebug --console=plain 2>&1 |
        Select-String -Pattern "^e:|error:|multiple definition|FAILED|BUILD SUCCESS" |
        Select-Object -First 20
}

Write-Host "=== 安装 ===" -ForegroundColor Cyan
& $adb install -r $apk 2>&1 | Select-Object -Last 1

Write-Host "=== 推送启动脚本 ===" -ForegroundColor Cyan
# 脚本以 shell 身份执行（am start 不能经 run-as），脚本内部再用 run-as 处理私有目录
& $adb push (Join-Path $PSScriptRoot "start_vm.sh") /data/local/tmp/start_vm.sh 2>&1 | Out-Null

& $adb shell "run-as com.vm.app rm -f files/vms/vm_1/logs/qemu-stderr.log files/vms/vm_1/logs/console.log"
& $adb logcat -c

Write-Host "=== 启动实例 ===" -ForegroundColor Cyan
& $adb shell "sh /data/local/tmp/start_vm.sh $Tag NAT"

Start-Sleep -Seconds $WaitsSeconds

Write-Host "`n=== 进程 ===" -ForegroundColor Cyan
& $adb shell "ps -A | grep vm.app"

Write-Host "`n=== 引擎日志 ===" -ForegroundColor Cyan
& $adb logcat -d -s VmNative:V VmRender:V VmGuestDpy:V VmEngine:V VmQemu:V VmInput:V 2>&1 |
    Select-Object -Last 25

Write-Host "`n=== QEMU stderr ===" -ForegroundColor Cyan
& $adb shell "run-as com.vm.app cat files/vms/vm_1/logs/qemu-stderr.log" 2>&1 |
    Select-Object -Last 30

Write-Host "`n=== 访客内核串口（尾部）===" -ForegroundColor Cyan
& $adb shell "run-as com.vm.app tail -n 30 files/vms/vm_1/logs/console.log" 2>&1

Write-Host "`n=== 崩溃信号 ===" -ForegroundColor Cyan
& $adb logcat -d 2>&1 |
    Select-String -Pattern "Fatal signal|F DEBUG|backtrace" | Select-Object -Last 8
