@echo off
chcp 65001 >nul
title MC 服务器一键配置
cd /d "%~dp0"
echo ============================================================
echo   MC 服务器一键配置 - 正在启动，请稍候...
echo ============================================================
echo.
if not exist "%~dp0scripts\install.ps1" (
    echo [错误] 未找到 scripts\install.ps1，请确认整合包文件完整。
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
echo.
echo [提示] 脚本已结束，按任意键关闭本窗口。
pause
