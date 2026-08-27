# LiteWAMP

LiteWAMP is a lightweight, portable Windows launcher for running multiple PHP versions with an optional MySQL server.

Project website: [litewamp.localphp.net](https://litewamp.localphp.net/)

It uses PHP's built-in development server, requires no Apache installation, does not register Windows services, and resolves every runtime path relative to `LiteWAMP.bat`. The complete local environment can therefore be moved to another directory or drive without changing the launcher.

> LiteWAMP is intended for local development only. PHP's built-in server and the default MySQL configuration must not be exposed to untrusted networks or used as a production stack.

## Features

- Discovers every PHP version stored directly under `PHP\`.
- Discovers every MySQL version stored directly under `MySQL\`.
- Supports spaces in runtime and project paths.
- Lets the user choose the PHP version, project document root, HTTP port, and optional MySQL version.
- Uses port `80` by default, making the project available at `http://localhost/` without an explicit port.
- Stores the selected environment in a generated `LiteWAMP.ini` file.
- Shows a configuration summary on later launches and lets the user reuse or replace it.
- Initializes a separate MySQL data directory for each MySQL version.
- Keeps PHP request logs visible in the LiteWAMP terminal.
- Starts MySQL without opening an additional terminal window.
- Stops PHP and performs a controlled MySQL shutdown when the user presses `Q`.
- Detects occupied HTTP and MySQL ports before starting services.

## Repository contents

The Git repository intentionally contains the launcher and documentation, but not third-party PHP/MySQL distributions or machine-generated database files.

This keeps the repository small and prevents local configuration, database contents, generated certificates, hostnames, logs, and vendor debug symbols from being published.

After cloning, add the desired official Windows ZIP distributions locally as described below.

## Requirements

- Windows 10 or Windows 11.
- `cmd.exe` and standard Windows command-line utilities.
- At least one Windows PHP ZIP distribution containing `php.exe`.
- Optionally, a MySQL Community Server Windows ZIP distribution containing `bin\mysqld.exe` and `bin\mysqladmin.exe`.
- The Microsoft Visual C++ Redistributable required by the selected PHP and MySQL builds.
- An available TCP port for PHP and, when enabled, port `3306` for MySQL.

Official downloads:

- [PHP for Windows](https://windows.php.net/)
- [MySQL Community Server](https://dev.mysql.com/downloads/mysql/)

For PHP CLI development, an x64 Non Thread Safe build is generally sufficient. Always choose a build compatible with the Windows architecture and installed Visual C++ runtime.

For MySQL, download the standard Windows ZIP archive, not the larger debug binaries and test-suite archive.

## Installation

### 1. Clone or download LiteWAMP

```powershell
git clone https://github.com/borindesign/LiteWAMP.git
cd LiteWAMP
```

The directory can be placed anywhere, for example:

```text
C:\Tools\LiteWAMP
D:\Development\LiteWAMP
E:\Portable\LiteWAMP
```

No path is hard-coded in the launcher.

### 2. Add PHP versions

Extract each PHP ZIP archive into a separate direct child of `PHP\`:

```text
LiteWAMP\
└── PHP\
    ├── php-8.2.30\
    │   ├── php.exe
    │   ├── php.ini
    │   └── ext\
    └── php-8.4.19\
        ├── php.exe
        ├── php.ini
        └── ext\
```

The directory name is used as the menu label. The displayed runtime version is read from `php.exe -n -v`, so an incorrect folder name does not change the detected version.

If the distribution does not contain `php.ini`, copy one of the supplied templates:

```powershell
Copy-Item php.ini-development php.ini
```

For a portable configuration, use a relative extension directory:

```ini
extension_dir = "ext"
```

Enable only the extensions required by the project. Typical MySQL applications use:

```ini
extension=mysqli
extension=pdo_mysql
```

Do not copy absolute `extension_dir` values from another computer, and do not enable Unix `.so` extensions in a Windows PHP configuration.

### 3. Add MySQL versions

Extract each MySQL Windows ZIP archive into a separate direct child of `MySQL\`:

```text
LiteWAMP\
└── MySQL\
    ├── mysql-8.0.46\
    │   └── bin\
    │       ├── mysqld.exe
    │       └── mysqladmin.exe
    └── mysql-8.4.x\
        └── bin\
            ├── mysqld.exe
            └── mysqladmin.exe
```

LiteWAMP creates these items when needed:

```text
mysql-version\
├── data\
├── logs\
│   ├── mysql-error.log
│   └── mysql.pid
└── litewamp.ini
```

Do not share one `data\` directory between different MySQL versions. Storage formats and upgrade rules can differ between releases.

## First run

Double-click `LiteWAMP.bat` or run it from a terminal:

```powershell
.\LiteWAMP.bat
```

When `LiteWAMP.ini` does not exist, the launcher asks for:

1. PHP version.
2. Project document root.
3. HTTP port.
4. MySQL version, or no database.

Press Enter at the HTTP port prompt to select port `80`.

After the wizard is completed, the selected configuration is saved to `LiteWAMP.ini` next to the launcher.

## Reusing or replacing a configuration

When `LiteWAMP.ini` already exists, LiteWAMP displays a complete summary and offers:

```text
[U] Use this configuration
[N] Create a new configuration and replace the saved one
[Q] Quit
```

Choosing `N` removes the previous generated configuration and starts the setup wizard again.

If a configured runtime or project directory no longer exists, the configuration is considered invalid and LiteWAMP starts a new setup automatically.

## Generated configuration

An example `LiteWAMP.ini` file looks like this:

```ini
format_version=1
php_version=php-8.4.19
project_dir=D:\Projects\example-app
http_port=80
mysql_enabled=1
mysql_version=mysql-8.0.46
mysql_port=3306
auto_shutdown=1
```

This file is machine-specific and is intentionally excluded from Git.

## Starting the environment

When the selected configuration starts, LiteWAMP:

1. Verifies that the HTTP port is available.
2. Initializes the selected MySQL data directory when necessary.
3. Starts MySQL in the background without a second terminal window.
4. Waits until MySQL responds.
5. Starts the PHP development server.
6. Displays PHP request logs in the main terminal.

When port `80` is selected, open `http://localhost/`. For another port, such as `8080`, open `http://localhost:8080/`.

## Stopping LiteWAMP safely

While the environment is running, the terminal displays:

```text
[Q] Stop LiteWAMP
```

Press `Q` to perform the controlled shutdown sequence:

1. Terminate the PHP development server.
2. Send `mysqladmin shutdown` to the MySQL instance started by LiteWAMP.
3. Confirm that both services have stopped.
4. Return to the main menu.

Do not close the terminal with the window close button while the environment is running. A Batch process cannot reliably execute cleanup code after its console is forcibly closed, and MySQL might remain active or be terminated without a controlled shutdown.

## MySQL initialization and credentials

When a selected MySQL version has no initialized `data\mysql` directory, LiteWAMP runs MySQL with `--initialize-insecure`.

This creates a local `root` account without an initial password. The generated server configuration binds MySQL to the local computer only.

This behavior is convenient for an isolated development environment but is not secure for production or an untrusted workstation.

If the root password is changed, automatic shutdown through the generated client configuration will no longer work unless valid credentials are made available to `mysqladmin`. Avoid storing reusable production credentials in this directory.

## Logs

### PHP

PHP request logs remain visible in the main LiteWAMP terminal while the server runs.

```text
127.0.0.1:53120 Accepted
127.0.0.1:53120 [200]: GET /
127.0.0.1:53120 Closing
```

### MySQL

MySQL writes its server log to:

```text
MySQL\mysql-version\logs\mysql-error.log
```

Use this file when MySQL does not initialize, start, or stop correctly.

## Adding or removing versions

To add a version:

1. Stop LiteWAMP by pressing `Q`.
2. Extract the runtime into a new direct child of `PHP\` or `MySQL\`.
3. Start LiteWAMP again.
4. Choose `N` when asked whether to reuse the saved configuration.

To remove a version:

1. Stop LiteWAMP.
2. Back up any required MySQL databases.
3. Remove the version directory.
4. Start LiteWAMP and create a new configuration.

## Moving the environment

The LiteWAMP directory can be copied or moved because runtime paths are resolved from the location of `LiteWAMP.bat`.

Before copying an environment that contains MySQL data:

1. Press `Q` and wait for the `MySQL stopped` confirmation.
2. Verify that no `mysqld.exe` process is running.
3. Copy the complete LiteWAMP directory.

For migration between MySQL versions, prefer a logical export and import using `mysqldump` rather than copying one version's physical data directory into another version.

## Project structure

```text
LiteWAMP\
├── LiteWAMP.bat       # Main interactive launcher
├── LiteWAMP.ini       # Generated locally; excluded from Git
├── PHP\               # Locally installed PHP ZIP distributions
└── MySQL\             # Locally installed MySQL ZIP distributions
```

## Troubleshooting

### The PHP version menu shows startup warnings

LiteWAMP detects versions with `php.exe -n -v`, which does not load `php.ini`. Warnings shown when the server starts usually indicate invalid entries in the selected `php.ini`.

Check that:

- `extension_dir = "ext"` is relative;
- every enabled extension has a corresponding Windows DLL;
- no Linux `.so` paths are enabled;
- required third-party DLL dependencies are installed.

### Port 80 is already occupied

IIS, another web server, a development tool, or another LiteWAMP instance may already be listening on port `80`. Stop the conflicting service or create a new configuration using another port such as `8080`.

### MySQL does not start

Check `MySQL\mysql-version\logs\mysql-error.log`. Also verify that port `3306` is free and that the selected ZIP contains `mysqld.exe` and `mysqladmin.exe`.

### A previous MySQL instance is still running

Do not start another server against the same data directory. Stop the existing process cleanly with its matching `mysqladmin.exe`, then restart LiteWAMP.

### The Batch file reports a missing label

`LiteWAMP.bat` must use Windows CRLF line endings. The included `.gitattributes` file enforces CRLF when the repository is checked out through Git.

### Paths containing special characters

Spaces are supported. Avoid exclamation marks (`!`) in the LiteWAMP path or project document root because the launcher uses delayed environment-variable expansion.

## Repository hygiene

The following local items are excluded from source control:

- PHP and MySQL vendor distributions;
- `LiteWAMP.ini`;
- MySQL data directories;
- generated certificates and private keys;
- PID and log files;
- debug symbol files.

Before publishing changes, verify that `git status` contains only launcher source, documentation, and intentional project metadata.

## Production use

LiteWAMP is not a production web server, process supervisor, security boundary, or database deployment system.

For production, use a supported web server and PHP process manager, protect database credentials, enable authentication, apply operating-system security updates, and follow the deployment guidance of the selected PHP and MySQL releases.
