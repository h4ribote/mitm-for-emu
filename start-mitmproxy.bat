@echo off
setlocal
rem ===================================================================
rem  start-mitmproxy.bat
rem  -------------------
rem  Start mitmproxy in Docker (Windows).
rem  ASCII-only on purpose: a .bat with non-ASCII bytes is mis-parsed
rem  by cmd.exe whenever the console codepage differs from the file's
rem  encoding. See android-system-cert-setup.md (Japanese) for details.
rem  Delayed expansion is intentionally NOT enabled so that passwords
rem  containing "!" are passed through unchanged.
rem
rem  On first run the CA files are generated under .\certs :
rem    certs\mitmproxy-ca-cert.pem  - CA certificate for Android (PEM)
rem    certs\mitmproxy-ca-cert.cer  - same, for user-cert install
rem    certs\mitmproxy-ca.pem       - includes PRIVATE KEY (keep secret)
rem
rem  Usage:
rem    start-mitmproxy.bat          mitmweb (with Web UI) [default]
rem    start-mitmproxy.bat web      mitmweb
rem    start-mitmproxy.bat proxy    mitmproxy (TUI)
rem    start-mitmproxy.bat dump     mitmdump (headless)
rem
rem  Configuration is read from .\.env (copy .env.example to .env). Keys:
rem    MITM_PROXY_USER  proxy auth username    (default mitmproxy)
rem    MITM_PROXY_PASS  proxy auth password    (empty = no authentication)
rem    MITMWEB_PASSWORD mitmweb Web UI password (empty = random token; web mode)
rem    PROXY_PORT       proxy listen port      (default 8080)
rem    WEB_PORT         Web UI port            (default 8081)
rem    CERT_DIR         cert output dir        (default .\certs)
rem    IMAGE            Docker image           (default mitmproxy/mitmproxy)
rem  Values already set in the environment override the .env file.
rem ===================================================================

rem --- settings ------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
set "MODE=%~1"

rem Load .env if present (do not overwrite already-defined variables).
if exist "%SCRIPT_DIR%.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%SCRIPT_DIR%.env") do (
    if not defined %%a set "%%a=%%b"
  )
)

if "%MODE%"=="" set "MODE=web"
if "%PROXY_PORT%"=="" set "PROXY_PORT=8080"
if "%WEB_PORT%"=="" set "WEB_PORT=8081"
if "%CERT_DIR%"=="" set "CERT_DIR=%SCRIPT_DIR%certs"
if "%IMAGE%"=="" set "IMAGE=mitmproxy/mitmproxy"
if "%MITM_PROXY_USER%"=="" set "MITM_PROXY_USER=mitmproxy"
set "CONTAINER_NAME=mitmproxy-emu"

rem connection_strategy=lazy: wait for the client TLS ClientHello (SNI) before
rem connecting upstream. Required for transparent/redsocks setups where the
rem CONNECT target is a raw IP (the real hostname is only in the SNI).
set "EXTRA_ARGS=--set connection_strategy=lazy"
set "AUTH_STATUS=disabled"
if not "%MITM_PROXY_PASS%"=="" (
  set "EXTRA_ARGS=%EXTRA_ARGS% --set proxyauth=%MITM_PROXY_USER%:%MITM_PROXY_PASS%"
  set "AUTH_STATUS=enabled (user: %MITM_PROXY_USER%)"
)

rem Protect the mitmweb Web UI (web mode only) when a password is configured.
set "WEB_ARGS="
set "WEB_AUTH_STATUS=disabled (random token in logs)"
if not "%MITMWEB_PASSWORD%"=="" (
  set "WEB_ARGS=--set web_password=%MITMWEB_PASSWORD%"
  set "WEB_AUTH_STATUS=enabled (password from .env)"
)

rem --- prerequisite checks -------------------------------------------
where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] docker not found. Please install Docker Desktop.
  exit /b 1
)

docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Cannot reach the Docker daemon. Please start Docker Desktop.
  exit /b 1
)

rem ensure cert output directory exists
if not exist "%CERT_DIR%" mkdir "%CERT_DIR%"

rem remove any leftover container with the same name
docker rm -f "%CONTAINER_NAME%" >nul 2>&1

rem --- decide launch command -----------------------------------------
if /i "%MODE%"=="web" (
  set "APP_CMD=mitmweb --web-host 0.0.0.0 --web-port %WEB_PORT% --listen-port %PROXY_PORT% %WEB_ARGS%"
  set "INTERACTIVE=-d"
  set "PORT_ARGS=-p %PROXY_PORT%:%PROXY_PORT% -p %WEB_PORT%:%WEB_PORT%"
) else if /i "%MODE%"=="proxy" (
  set "APP_CMD=mitmproxy --listen-port %PROXY_PORT%"
  set "INTERACTIVE=-it"
  set "PORT_ARGS=-p %PROXY_PORT%:%PROXY_PORT%"
) else if /i "%MODE%"=="dump" (
  set "APP_CMD=mitmdump --listen-port %PROXY_PORT%"
  set "INTERACTIVE=-it"
  set "PORT_ARGS=-p %PROXY_PORT%:%PROXY_PORT%"
) else (
  echo [ERROR] unknown mode: %MODE%  ^(use: web ^| proxy ^| dump^)
  exit /b 1
)

rem --- run -----------------------------------------------------------
echo ===================================================================
echo  Starting mitmproxy
echo    mode        : %MODE%
echo    proxy port  : %PROXY_PORT%
if /i "%MODE%"=="web" echo    Web UI      : http://127.0.0.1:%WEB_PORT%
if /i "%MODE%"=="web" echo    Web UI auth : %WEB_AUTH_STATUS%
echo    proxy auth  : %AUTH_STATUS%
echo    cert dir    : %CERT_DIR%
echo    docker image: %IMAGE%
echo ===================================================================

docker run --rm %INTERACTIVE% ^
  --name "%CONTAINER_NAME%" ^
  %PORT_ARGS% ^
  -v "%CERT_DIR%:/home/mitmproxy/.mitmproxy" ^
  "%IMAGE%" ^
  %APP_CMD% %EXTRA_ARGS%

if /i "%MODE%"=="web" (
  echo.
  echo Started in background.
  echo   logs : docker logs -f %CONTAINER_NAME%
  echo   stop : docker stop %CONTAINER_NAME%
  echo   Web UI : http://127.0.0.1:%WEB_PORT%
)
if /i "%MODE%"=="web" if not "%MITMWEB_PASSWORD%"=="" echo   ^(Web UI is password-protected; enter the password or use ?token=^<password^>^)

endlocal
