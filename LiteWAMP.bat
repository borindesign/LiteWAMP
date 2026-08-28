@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

title LiteWAMP Manager
color 0A

rem ============================================================
rem  LiteWAMP - PHP and MySQL portable development launcher
rem  All paths are resolved from the directory containing this BAT.
rem ============================================================

set "APP_ROOT=%~dp0"
if "%APP_ROOT:~-1%"=="\" set "APP_ROOT=%APP_ROOT:~0,-1%"

set "PHP_ROOT=%APP_ROOT%\PHP"
set "MYSQL_ROOT=%APP_ROOT%\MySQL"
set "CONFIG_FILE=%APP_ROOT%\LiteWAMP.ini"
set "MYSQL_STARTED_BY_US=0"

if not exist "%PHP_ROOT%" mkdir "%PHP_ROOT%" >nul 2>&1
if not exist "%MYSQL_ROOT%" mkdir "%MYSQL_ROOT%" >nul 2>&1

:BOOT
cls
call :HEADER

if not exist "%CONFIG_FILE%" goto FIRST_CONFIGURATION

call :READ_CONFIG
call :VALIDATE_CONFIG
if errorlevel 1 (
    color 0E
    echo.
    echo  La configurazione salvata non e' piu' utilizzabile.
    echo  Una cartella, una versione o un valore configurato non esiste piu'.
    echo  Verra' avviata una nuova configurazione.
    echo.
    pause
    color 0A
    goto RESET_CONFIGURATION
)

call :SHOW_CONFIGURATION
echo.
echo  [U] Usa questa configurazione
echo  [E] Configura PHP: estensioni e opzioni
echo  [N] Crea una nuova configurazione e sostituisci quella salvata
echo  [Q] Esci
echo.
choice /C UENQ /N /M "Scelta: "
if errorlevel 4 goto :EOF
if errorlevel 3 goto RESET_CONFIGURATION
if errorlevel 2 goto MANAGE_PHP
if errorlevel 1 goto START_ENVIRONMENT

:MANAGE_PHP
if not exist "%APP_ROOT%\LiteWAMP.PhpConfig.ps1" (
    color 0C
    echo.
    echo  [ERRORE] Gestore configurazione PHP non trovato:
    echo  "%APP_ROOT%\LiteWAMP.PhpConfig.ps1"
    echo.
    pause
    color 0A
    goto BOOT
)

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" (
    color 0C
    echo.
    echo  [ERRORE] Windows PowerShell 5.1 non e' disponibile.
    echo  Percorso previsto: "%POWERSHELL_EXE%"
    echo.
    pause
    color 0A
    goto BOOT
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%APP_ROOT%\LiteWAMP.PhpConfig.ps1" -PhpRoot "%PHP_ROOT%"
if errorlevel 1 (
    color 0C
    echo.
    echo  [ERRORE] Il gestore della configurazione PHP non e' stato avviato correttamente.
    echo.
    pause
    color 0A
)
goto BOOT

:FIRST_CONFIGURATION
echo  Nessuna configurazione salvata.
echo  La procedura iniziale creera' automaticamente LiteWAMP.ini.
echo.
goto CONFIGURE

:RESET_CONFIGURATION
if exist "%CONFIG_FILE%" del /Q "%CONFIG_FILE%" >nul 2>&1
goto CONFIGURE

:CONFIGURE
call :SELECT_PHP
if errorlevel 1 goto :EOF

call :SELECT_PROJECT
if errorlevel 1 goto :EOF

call :SELECT_HTTP_PORT
if errorlevel 1 goto :EOF

call :SELECT_MYSQL
if errorlevel 1 goto :EOF

set "CFG_MYSQL_PORT=3306"
set "CFG_AUTO_SHUTDOWN=1"

call :SAVE_CONFIG
if errorlevel 1 (
    color 0C
    echo.
    echo  [ERRORE] Impossibile salvare "%CONFIG_FILE%".
    pause
    goto :EOF
)

color 0A
cls
call :HEADER
echo  Configurazione salvata correttamente.
call :SHOW_CONFIGURATION
echo.
choice /C AQ /N /M "[A] Avvia ora  [Q] Esci: "
if errorlevel 2 goto :EOF
goto START_ENVIRONMENT

:START_ENVIRONMENT
set "PHP_HOME=%PHP_ROOT%\%CFG_PHP_VERSION%"
set "PHP_EXE=%PHP_HOME%\php.exe"
set "PHP_INI=%PHP_HOME%\php.ini"

call :IS_PORT_LISTENING "%CFG_HTTP_PORT%"
if not errorlevel 1 (
    color 0C
    echo.
    echo  [ERRORE] La porta HTTP %CFG_HTTP_PORT% e' gia' occupata.
    echo  Arresta il programma che la utilizza oppure crea una nuova configurazione.
    echo.
    pause
    color 0A
    goto BOOT
)

set "MYSQL_STARTED_BY_US=0"
if "%CFG_MYSQL_ENABLED%"=="1" (
    call :START_MYSQL
    if errorlevel 1 (
        color 0C
        echo.
        echo  [ERRORE] MySQL non e' stato avviato.
        echo  Il server PHP non verra' avviato.
        echo.
        pause
        color 0A
        goto BOOT
    )
)

cls
color 0B
call :HEADER
echo  AMBIENTE ATTIVO
echo  ----------------------------------------------------------
echo  PHP:       %CFG_PHP_VERSION%
if "%CFG_MYSQL_ENABLED%"=="1" (
    echo  MySQL:     %CFG_MYSQL_VERSION% su 127.0.0.1:%CFG_MYSQL_PORT%
) else (
    echo  MySQL:     disabilitato
)
echo  ROOT:      "%CFG_PROJECT_DIR%"
if "%CFG_HTTP_PORT%"=="80" (
    echo  URL:       http://localhost/
) else (
    echo  URL:       http://localhost:%CFG_HTTP_PORT%/
)
echo  ----------------------------------------------------------
echo.
echo  LOG DEL SERVER PHP
echo  ----------------------------------------------------------
echo  Premi Q per arrestare in sicurezza PHP e MySQL.
echo  Non chiudere questa finestra con la X durante l'esecuzione.
echo.

call :START_PHP
if errorlevel 1 (
    color 0C
    echo.
    echo  [ERRORE] Il server PHP non e' stato avviato.
    if "!MYSQL_STARTED_BY_US!"=="1" call :STOP_MYSQL
    echo.
    pause
    color 0A
    goto BOOT
)

echo.
choice /C Q /N /M "[Q] Arresta LiteWAMP: "

call :STOP_PHP
if "%MYSQL_STARTED_BY_US%"=="1" if "%CFG_AUTO_SHUTDOWN%"=="1" call :STOP_MYSQL

echo.
echo  Ambiente arrestato.
pause
color 0A
goto BOOT

:START_PHP
set "PHP_PID="
set "PHP_READY=0"

if exist "%PHP_INI%" (
    start "" /B "%PHP_EXE%" -c "%PHP_INI%" -S 127.0.0.1:%CFG_HTTP_PORT% -t "%CFG_PROJECT_DIR%"
) else (
    echo  [AVVISO] php.ini non presente: PHP usera' la configurazione predefinita.
    echo.
    start "" /B "%PHP_EXE%" -S 127.0.0.1:%CFG_HTTP_PORT% -t "%CFG_PROJECT_DIR%"
)

for /L %%I in (1,1,15) do (
    if "!PHP_READY!"=="0" (
        call :IS_PORT_LISTENING "%CFG_HTTP_PORT%"
        if not errorlevel 1 (
            set "PHP_READY=1"
        ) else (
            ping 127.0.0.1 -n 2 >nul
        )
    )
)

if "%PHP_READY%"=="0" exit /B 1

for /F "tokens=5" %%P in ('netstat -ano -p TCP ^| findstr /R /C:"127.0.0.1:%CFG_HTTP_PORT% .*LISTENING"') do (
    if not defined PHP_PID set "PHP_PID=%%P"
)

if not defined PHP_PID exit /B 1
echo  Server PHP pronto. PID: %PHP_PID%
exit /B 0

:STOP_PHP
if not defined PHP_PID exit /B 0
echo.
echo  Arresto del server PHP...
taskkill /F /PID %PHP_PID% /T >nul 2>&1
call :IS_PORT_LISTENING "%CFG_HTTP_PORT%"
if not errorlevel 1 (
    color 0E
    echo  [AVVISO] La porta PHP %CFG_HTTP_PORT% risulta ancora attiva.
) else (
    echo  PHP arrestato.
)
set "PHP_PID="
exit /B 0

:SELECT_PHP
cls
call :HEADER
echo  VERSIONI PHP DISPONIBILI
echo  ----------------------------------------------------------

set "PHP_COUNT=0"
for /D %%D in ("%PHP_ROOT%\*") do (
    if exist "%%~fD\php.exe" (
        set /A PHP_COUNT+=1
        set "PHP_FOLDER[!PHP_COUNT!]=%%~nxD"
        set "PHP_CURRENT_VERSION="
        rem -n ignores php.ini: version detection must never load project extensions.
        for /F "tokens=2" %%V in ('""%%~fD\php.exe" -n -v 2^>nul"') do (
            if not defined PHP_CURRENT_VERSION set "PHP_CURRENT_VERSION=%%V"
        )
        if not defined PHP_CURRENT_VERSION set "PHP_CURRENT_VERSION=versione non rilevata"
        set "PHP_DETECTED[!PHP_COUNT!]=!PHP_CURRENT_VERSION!"
    )
)

if "%PHP_COUNT%"=="0" (
    color 0C
    echo.
    echo  [ERRORE] Nessuna versione PHP trovata.
    echo.
    echo  Estrai ogni versione in una sottocartella di:
    echo  "%PHP_ROOT%"
    echo.
    echo  Esempio: PHP\php-8.4\php.exe
    echo.
    pause
    color 0A
    exit /B 1
)

for /L %%I in (1,1,%PHP_COUNT%) do echo  [%%I] !PHP_FOLDER[%%I]! ^(!PHP_DETECTED[%%I]!^)
echo  [Q] Esci
echo.

:SELECT_PHP_INPUT
set "PHP_CHOICE="
set /P "PHP_CHOICE=Seleziona PHP: "
if /I "!PHP_CHOICE!"=="Q" exit /B 1
set "PHP_SELECTION_VALID=0"
for /L %%I in (1,1,%PHP_COUNT%) do if "!PHP_CHOICE!"=="%%I" (
    set "CFG_PHP_VERSION=!PHP_FOLDER[%%I]!"
    set "PHP_SELECTION_VALID=1"
)
if "!PHP_SELECTION_VALID!"=="0" (
    echo  Scelta non valida.
    goto SELECT_PHP_INPUT
)
exit /B 0

:SELECT_PROJECT
cls
call :HEADER
echo  CARTELLA DEL PROGETTO
echo  ----------------------------------------------------------
echo  Inserisci la document root servita da PHP.
echo  Premi INVIO per usare la cartella di LiteWAMP:
echo  "%APP_ROOT%"
echo.

:SELECT_PROJECT_INPUT
set "RAW_PROJECT="
set /P "RAW_PROJECT=Percorso: "
if not defined RAW_PROJECT set "RAW_PROJECT=%APP_ROOT%"
set "RAW_PROJECT=!RAW_PROJECT:"=!"
if not exist "!RAW_PROJECT!" (
    color 0C
    echo  [ERRORE] Cartella non trovata: "!RAW_PROJECT!"
    color 0A
    goto SELECT_PROJECT_INPUT
)
set "CFG_PROJECT_DIR=!RAW_PROJECT!"
exit /B 0

:SELECT_HTTP_PORT
cls
call :HEADER
echo  PORTA HTTP
echo  ----------------------------------------------------------
echo  Inserisci la porta del server PHP.
echo  Premi INVIO per usare la porta 80 e aprire http://localhost/
echo.

:SELECT_HTTP_PORT_INPUT
set "RAW_PORT="
set /P "RAW_PORT=Porta [80]: "
if not defined RAW_PORT set "RAW_PORT=80"
call :VALIDATE_PORT "!RAW_PORT!"
if errorlevel 1 (
    echo  Inserisci un numero compreso tra 1 e 65535.
    goto SELECT_HTTP_PORT_INPUT
)
set "CFG_HTTP_PORT=!VALIDATED_PORT!"
exit /B 0

:SELECT_MYSQL
cls
call :HEADER
echo  VERSIONI MYSQL DISPONIBILI
echo  ----------------------------------------------------------
echo  [0] Non avviare MySQL

set "MYSQL_COUNT=0"
for /D %%D in ("%MYSQL_ROOT%\*") do (
    if exist "%%~fD\bin\mysqld.exe" (
        set /A MYSQL_COUNT+=1
        set "MYSQL_FOLDER[!MYSQL_COUNT!]=%%~nxD"
        echo  [!MYSQL_COUNT!] %%~nxD
    )
)
echo  [Q] Esci
echo.

:SELECT_MYSQL_INPUT
set "MYSQL_CHOICE="
set /P "MYSQL_CHOICE=Seleziona MySQL: "
if /I "!MYSQL_CHOICE!"=="Q" exit /B 1
if "!MYSQL_CHOICE!"=="0" (
    set "CFG_MYSQL_ENABLED=0"
    set "CFG_MYSQL_VERSION="
    exit /B 0
)
set "MYSQL_SELECTION_VALID=0"
for /L %%I in (1,1,%MYSQL_COUNT%) do if "!MYSQL_CHOICE!"=="%%I" (
    set "CFG_MYSQL_ENABLED=1"
    set "CFG_MYSQL_VERSION=!MYSQL_FOLDER[%%I]!"
    set "MYSQL_SELECTION_VALID=1"
)
if "!MYSQL_SELECTION_VALID!"=="0" (
    echo  Scelta non valida.
    goto SELECT_MYSQL_INPUT
)
exit /B 0

:READ_CONFIG
set "CFG_FORMAT_VERSION="
set "CFG_PHP_VERSION="
set "CFG_PROJECT_DIR="
set "CFG_HTTP_PORT="
set "CFG_MYSQL_ENABLED="
set "CFG_MYSQL_VERSION="
set "CFG_MYSQL_PORT="
set "CFG_AUTO_SHUTDOWN="

for /F "usebackq tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
    if /I "%%A"=="format_version" set "CFG_FORMAT_VERSION=%%B"
    if /I "%%A"=="php_version" set "CFG_PHP_VERSION=%%B"
    if /I "%%A"=="project_dir" set "CFG_PROJECT_DIR=%%B"
    if /I "%%A"=="http_port" set "CFG_HTTP_PORT=%%B"
    if /I "%%A"=="mysql_enabled" set "CFG_MYSQL_ENABLED=%%B"
    if /I "%%A"=="mysql_version" set "CFG_MYSQL_VERSION=%%B"
    if /I "%%A"=="mysql_port" set "CFG_MYSQL_PORT=%%B"
    if /I "%%A"=="auto_shutdown" set "CFG_AUTO_SHUTDOWN=%%B"
)
exit /B 0

:VALIDATE_CONFIG
if not "%CFG_FORMAT_VERSION%"=="1" exit /B 1
if not exist "%PHP_ROOT%\%CFG_PHP_VERSION%\php.exe" exit /B 1
if not exist "%CFG_PROJECT_DIR%" exit /B 1
call :VALIDATE_PORT "%CFG_HTTP_PORT%"
if errorlevel 1 exit /B 1
set "CFG_HTTP_PORT=%VALIDATED_PORT%"
if not "%CFG_MYSQL_ENABLED%"=="0" if not "%CFG_MYSQL_ENABLED%"=="1" exit /B 1
if "%CFG_MYSQL_ENABLED%"=="1" (
    if not exist "%MYSQL_ROOT%\%CFG_MYSQL_VERSION%\bin\mysqld.exe" exit /B 1
    call :VALIDATE_PORT "%CFG_MYSQL_PORT%"
    if errorlevel 1 exit /B 1
    set "CFG_MYSQL_PORT=!VALIDATED_PORT!"
)
if not "%CFG_AUTO_SHUTDOWN%"=="0" if not "%CFG_AUTO_SHUTDOWN%"=="1" exit /B 1
exit /B 0

:SAVE_CONFIG
>"%CONFIG_FILE%" echo format_version=1
>>"%CONFIG_FILE%" echo php_version=!CFG_PHP_VERSION!
>>"%CONFIG_FILE%" echo project_dir=!CFG_PROJECT_DIR!
>>"%CONFIG_FILE%" echo http_port=!CFG_HTTP_PORT!
>>"%CONFIG_FILE%" echo mysql_enabled=!CFG_MYSQL_ENABLED!
>>"%CONFIG_FILE%" echo mysql_version=!CFG_MYSQL_VERSION!
>>"%CONFIG_FILE%" echo mysql_port=!CFG_MYSQL_PORT!
>>"%CONFIG_FILE%" echo auto_shutdown=!CFG_AUTO_SHUTDOWN!
if not exist "%CONFIG_FILE%" exit /B 1
exit /B 0

:SHOW_CONFIGURATION
echo.
echo  CONFIGURAZIONE SALVATA
echo  ----------------------------------------------------------
echo  PHP:       %CFG_PHP_VERSION%
echo  ROOT:      "%CFG_PROJECT_DIR%"
if "%CFG_HTTP_PORT%"=="80" (
    echo  URL:       http://localhost/
) else (
    echo  URL:       http://localhost:%CFG_HTTP_PORT%/
)
if "%CFG_MYSQL_ENABLED%"=="1" (
    echo  MySQL:     %CFG_MYSQL_VERSION%
    echo  DB:        127.0.0.1:%CFG_MYSQL_PORT%
) else (
    echo  MySQL:     disabilitato
)
echo  ----------------------------------------------------------
exit /B 0

:START_MYSQL
set "MYSQL_HOME=%MYSQL_ROOT%\%CFG_MYSQL_VERSION%"
set "MYSQL_EXE=%MYSQL_HOME%\bin\mysqld.exe"
set "MYSQL_ADMIN=%MYSQL_HOME%\bin\mysqladmin.exe"
set "MYSQL_INI=%MYSQL_HOME%\litewamp.ini"
set "MYSQL_DATA=%MYSQL_HOME%\data"
set "MYSQL_LOGS=%MYSQL_HOME%\logs"
set "MYSQL_PID=%MYSQL_LOGS%\mysql.pid"
set "MYSQL_LOG=%MYSQL_LOGS%\mysql-error.log"

call :IS_PORT_LISTENING "%CFG_MYSQL_PORT%"
if not errorlevel 1 (
    echo.
    echo  [ERRORE] La porta MySQL %CFG_MYSQL_PORT% e' gia' occupata.
    exit /B 1
)

if not exist "%MYSQL_DATA%" mkdir "%MYSQL_DATA%" >nul 2>&1
if not exist "%MYSQL_LOGS%" mkdir "%MYSQL_LOGS%" >nul 2>&1

if not exist "%MYSQL_INI%" (
    >"%MYSQL_INI%" echo [client]
    >>"%MYSQL_INI%" echo host=localhost
    >>"%MYSQL_INI%" echo port=%CFG_MYSQL_PORT%
    >>"%MYSQL_INI%" echo user=root
    >>"%MYSQL_INI%" echo.
    >>"%MYSQL_INI%" echo [mysqld]
    >>"%MYSQL_INI%" echo bind-address=127.0.0.1
    >>"%MYSQL_INI%" echo port=%CFG_MYSQL_PORT%
)

if not exist "%MYSQL_DATA%\mysql" (
    dir /B "%MYSQL_DATA%" 2>nul | findstr . >nul
    if not errorlevel 1 (
        echo.
        echo  [ERRORE] La cartella data contiene file ma non sembra inizializzata.
        echo  Controlla: "%MYSQL_DATA%"
        exit /B 1
    )

    echo.
    echo  Prima inizializzazione di %CFG_MYSQL_VERSION%...
    echo  L'utente root verra' creato senza password per lo sviluppo locale.
    "%MYSQL_EXE%" --defaults-file="%MYSQL_INI%" --initialize-insecure --basedir="%MYSQL_HOME%" --datadir="%MYSQL_DATA%"
    if errorlevel 1 (
        echo  [ERRORE] Inizializzazione MySQL non riuscita.
        exit /B 1
    )
)

echo.
echo  Avvio di %CFG_MYSQL_VERSION%...
if exist "%MYSQL_PID%" del /Q "%MYSQL_PID%" >nul 2>&1
start "" /B "%MYSQL_EXE%" --defaults-file="%MYSQL_INI%" --basedir="%MYSQL_HOME%" --datadir="%MYSQL_DATA%" --pid-file="%MYSQL_PID%" --log-error="%MYSQL_LOG%"

set "MYSQL_READY=0"
for /L %%I in (1,1,30) do (
    if "!MYSQL_READY!"=="0" (
        "%MYSQL_ADMIN%" --defaults-file="%MYSQL_INI%" --protocol=tcp ping --silent >nul 2>&1
        if not errorlevel 1 (
            set "MYSQL_READY=1"
        ) else (
            ping 127.0.0.1 -n 2 >nul
        )
    )
)

if "%MYSQL_READY%"=="0" (
    echo  [ERRORE] MySQL non ha risposto entro 30 secondi.
    echo  Log: "%MYSQL_LOG%"
    exit /B 1
)

set "MYSQL_STARTED_BY_US=1"
echo  MySQL pronto su 127.0.0.1:%CFG_MYSQL_PORT%.
exit /B 0

:STOP_MYSQL
echo.
echo  Arresto pulito di MySQL...
"%MYSQL_ADMIN%" --defaults-file="%MYSQL_INI%" --protocol=tcp shutdown >nul 2>&1
if errorlevel 1 (
    color 0E
    echo  [AVVISO] Arresto automatico non riuscito.
    echo  Verifica il processo MySQL e il file "%MYSQL_LOG%".
) else (
    echo  MySQL arrestato.
)
set "MYSQL_STARTED_BY_US=0"
exit /B 0

:VALIDATE_PORT
setlocal EnableDelayedExpansion
set "CHECK_PORT=%~1"
if not defined CHECK_PORT endlocal & exit /B 1
for /F "delims=0123456789" %%A in ("!CHECK_PORT!") do endlocal & exit /B 1
if not "!CHECK_PORT:~5!"=="" endlocal & exit /B 1

:TRIM_PORT_ZERO
if not "!CHECK_PORT!"=="0" if "!CHECK_PORT:~0,1!"=="0" (
    set "CHECK_PORT=!CHECK_PORT:~1!"
    goto TRIM_PORT_ZERO
)
set /A CHECK_PORT_NUMBER=CHECK_PORT + 0 >nul 2>&1
if !CHECK_PORT_NUMBER! LSS 1 endlocal & exit /B 1
if !CHECK_PORT_NUMBER! GTR 65535 endlocal & exit /B 1
endlocal & set "VALIDATED_PORT=%CHECK_PORT_NUMBER%" & exit /B 0

:IS_PORT_LISTENING
netstat -ano -p TCP 2>nul | findstr /R /C:":%~1 .*LISTENING" >nul
exit /B %ERRORLEVEL%

:HEADER
echo  ##########################################################
echo  #                    LITEWAMP MANAGER                    #
echo  ##########################################################
echo.
exit /B 0
