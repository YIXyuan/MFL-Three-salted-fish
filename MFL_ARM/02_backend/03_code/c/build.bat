@echo off

chcp 65001 >nul
setlocal

set VCVARS=D:\MicrosoftVS\BuildTools\VC\Auxiliary\Build\vcvars64.bat
if not exist "%VCVARS%" (
  echo [ERROR] vcvars64.bat not found: %VCVARS%
  exit /b 1
)
call "%VCVARS%" >nul 2>&1

if not exist build mkdir build

echo [1/4] build test_head.exe
cl /nologo /O2 /std:c11 /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /Fe:build\test_head.exe /Fo:build\ test\test_head.c src\head.c /I src
if errorlevel 1 goto :fail

echo [2/4] build test_head_qdq.exe
cl /nologo /O2 /std:c11 /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /DMFL_HEAD_QDQ=1 /Fe:build\test_head_qdq.exe /Fo:build\ test\test_head.c src\head.c /I src
if errorlevel 1 goto :fail

echo [3/4] build head_cli.exe
cl /nologo /O2 /std:c11 /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /Fe:build\head_cli.exe /Fo:build\ app\head_cli.c src\fpga_if.c src\head.c /I src
if errorlevel 1 goto :fail

echo [4/4] build test_service.exe
cl /nologo /O2 /std:c11 /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /Fe:build\test_service.exe /Fo:build\ test\test_service.c src\head_service.c src\head.c /I src
if errorlevel 1 goto :fail

echo.
echo === float path (reference: head_fp32) ===
build\test_head.exe weights\head_weights.bin test_vectors
echo.
echo === QDQ path (reference: model_int8) ===
build\test_head_qdq.exe weights\head_weights.bin test_vectors
goto :eof

:fail
echo [ERROR] build failed
exit /b 1
