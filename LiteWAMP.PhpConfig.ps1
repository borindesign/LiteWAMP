[CmdletBinding()]
param(
    [string]$PhpRoot = '',
    [switch]$SmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:AppRoot = Split-Path -Parent $script:ScriptPath
if ([string]::IsNullOrWhiteSpace($PhpRoot)) { $PhpRoot = Join-Path $script:AppRoot 'PHP' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ExtensionStates = @{}
$script:OptionStates = @{}
$script:OptionControls = @{}
$script:Version = $null
$script:SelectedIndex = -1
$script:Loading = $false
$script:IsDirty = $false
$script:StatusBase = ''
$script:ExtensionBlockStart = '; BEGIN LiteWAMP managed extensions'
$script:ExtensionBlockEnd = '; END LiteWAMP managed extensions'
$script:OptionBlockStart = '; BEGIN LiteWAMP managed settings'
$script:OptionBlockEnd = '; END LiteWAMP managed settings'
$script:ZendExtensions = @('opcache', 'xdebug')
$script:CommonExtensions = @('curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'pdo_sqlite', 'sodium', 'sqlite3', 'zip')
$script:OptionDefinitions = @(
    [pscustomobject]@{ Name = 'allow_url_fopen'; Kind = 'Boolean'; Default = 'On'; Minimum = $null; AllowMinusOne = $false; Description = 'Consente l''apertura di URL tramite i wrapper fopen.' },
    [pscustomobject]@{ Name = 'display_errors'; Kind = 'Boolean'; Default = 'On'; Minimum = $null; AllowMinusOne = $false; Description = 'Mostra gli errori nell''output; utile nello sviluppo locale.' },
    [pscustomobject]@{ Name = 'log_errors'; Kind = 'Boolean'; Default = 'Off'; Minimum = $null; AllowMinusOne = $false; Description = 'Registra gli errori nel log configurato da PHP o dal server.' },
    [pscustomobject]@{ Name = 'short_open_tag'; Kind = 'Boolean'; Default = 'Off'; Minimum = $null; AllowMinusOne = $false; Description = 'Abilita i tag <? brevi; deprecata a partire da PHP 8.5.' },
    [pscustomobject]@{ Name = 'expose_php'; Kind = 'Boolean'; Default = 'On'; Minimum = $null; AllowMinusOne = $false; Description = 'Espone la presenza di PHP nelle intestazioni HTTP.' },
    [pscustomobject]@{ Name = 'max_execution_time'; Kind = 'Integer'; Default = '30'; Minimum = 0; AllowMinusOne = $false; Description = 'Tempo massimo di esecuzione in secondi; 0 significa nessun limite.' },
    [pscustomobject]@{ Name = 'max_input_time'; Kind = 'Integer'; Default = '-1'; Minimum = 0; AllowMinusOne = $true; Description = 'Tempo massimo per analizzare l''input; -1 usa max_execution_time, 0 e'' illimitato.' },
    [pscustomobject]@{ Name = 'post_max_size'; Kind = 'Size'; Default = '8M'; Minimum = 0; AllowMinusOne = $false; Description = 'Dimensione massima dei dati POST; deve superare upload_max_filesize.' },
    [pscustomobject]@{ Name = 'upload_max_filesize'; Kind = 'Size'; Default = '2M'; Minimum = 0; AllowMinusOne = $false; Description = 'Dimensione massima di un singolo file caricato.' },
    [pscustomobject]@{ Name = 'max_file_uploads'; Kind = 'Integer'; Default = '20'; Minimum = 0; AllowMinusOne = $false; Description = 'Numero massimo di file caricabili nella stessa richiesta.' },
    [pscustomobject]@{ Name = 'max_input_vars'; Kind = 'Integer'; Default = '1000'; Minimum = 0; AllowMinusOne = $false; Description = 'Numero massimo di variabili accettate per GET, POST e COOKIE.' },
    [pscustomobject]@{ Name = 'memory_limit'; Kind = 'Size'; Default = '128M'; Minimum = 0; AllowMinusOne = $true; Description = 'Memoria massima per uno script; -1 significa nessun limite.' }
)

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'LiteWAMP - Configurazione PHP', 'OK', 'Error')
}

function Get-ExtensionId([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $id = $Value.Trim().Trim('"').Trim("'").Replace('/', '\')
    $id = [System.IO.Path]::GetFileName($id).ToLowerInvariant()
    if ($id.StartsWith('php_')) { $id = $id.Substring(4) }
    if ($id.EndsWith('.dll')) { $id = $id.Substring(0, $id.Length - 4) }
    return $id
}

function Get-ExtensionDirective([string]$Line) {
    $pattern = '^(?<indent>\s*)(?<disabled>;\s*)?(?<kind>zend_extension|extension)\s*=\s*(?<value>"[^"]*"|''[^'']*''|[^;\s]+)(?<tail>\s*(?:;.*)?)$'
    $match = [regex]::Match($Line, $pattern, 'IgnoreCase')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Id = Get-ExtensionId $match.Groups['value'].Value
        Enabled = -not $match.Groups['disabled'].Success
        Indent = $match.Groups['indent'].Value
        Tail = $match.Groups['tail'].Value
    }
}

function Read-TextDocument([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    $preamble = [byte[]]@()
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($false); $offset = 3; $preamble = [byte[]](0xEF, 0xBB, 0xBF)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false); $offset = 2; $preamble = [byte[]](0xFF, 0xFE)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false); $offset = 2; $preamble = [byte[]](0xFE, 0xFF)
    } else {
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$utf8.GetString($bytes)
            $encoding = New-Object System.Text.UTF8Encoding($false)
        } catch { $encoding = [System.Text.Encoding]::Default }
    }
    $length = $bytes.Length - $offset
    $text = if ($length -gt 0) { $encoding.GetString($bytes, $offset, $length) } else { '' }
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { "`r`n" }
    return [pscustomobject]@{ Text = $text; Encoding = $encoding; Preamble = $preamble; NewLine = $newLine }
}

function Write-TextDocument([string]$Path, [string]$Text, [object]$Document) {
    $body = $Document.Encoding.GetBytes($Text)
    $bytes = New-Object byte[] ($Document.Preamble.Length + $body.Length)
    if ($Document.Preamble.Length) { [Buffer]::BlockCopy($Document.Preamble, 0, $bytes, 0, $Document.Preamble.Length) }
    if ($body.Length) { [Buffer]::BlockCopy($body, 0, $bytes, $Document.Preamble.Length, $body.Length) }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-Php([string]$PhpExe, [string]$Arguments, [string]$WorkingDirectory) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $PhpExe
    $info.Arguments = $Arguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.Result; Error = $errorTask.Result }
}

function Get-Versions {
    if (-not (Test-Path -LiteralPath $PhpRoot -PathType Container)) { return @() }
    $result = @()
    foreach ($folder in Get-ChildItem -LiteralPath $PhpRoot -Directory -ErrorAction SilentlyContinue) {
        $exe = Join-Path $folder.FullName 'php.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $detected = 'versione non rilevata'
        try {
            $check = Invoke-Php $exe '-n -r "echo PHP_VERSION;"' $folder.FullName
            if ($check.ExitCode -eq 0 -and $check.Output.Trim()) { $detected = $check.Output.Trim() }
        } catch { }
        $result += [pscustomobject]@{
            Name = $folder.Name; DisplayName = "$($folder.Name)  (PHP $detected)"; Home = $folder.FullName; PhpExe = $exe
            IniPath = Join-Path $folder.FullName 'php.ini'; DevelopmentIni = Join-Path $folder.FullName 'php.ini-development'
            ProductionIni = Join-Path $folder.FullName 'php.ini-production'; ExtPath = Join-Path $folder.FullName 'ext'
        }
    }
    return @($result | Sort-Object Name)
}

function Get-ConfiguredVersion {
    $path = Join-Path $script:AppRoot 'LiteWAMP.ini'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match '^php_version=(.*)$') { return $matches[1].Trim() }
    }
    return ''
}

function Get-ExtensionStates([object]$Version) {
    $enabled = @{}
    if (Test-Path -LiteralPath $Version.IniPath -PathType Leaf) {
        $doc = Read-TextDocument $Version.IniPath
        foreach ($line in [regex]::Split($doc.Text, "`r`n|`n|`r")) {
            $directive = Get-ExtensionDirective $line
            if ($null -ne $directive -and $directive.Enabled) { $enabled[$directive.Id] = $true }
        }
    }
    $result = @{}
    if (Test-Path -LiteralPath $Version.ExtPath -PathType Container) {
        foreach ($dll in Get-ChildItem -LiteralPath $Version.ExtPath -Filter 'php_*.dll' -File -ErrorAction SilentlyContinue) {
            $id = Get-ExtensionId $dll.Name
            if (-not $id) { continue }
            $isEnabled = $enabled.ContainsKey($id)
            $result[$id] = [pscustomobject]@{
                Id = $id; Enabled = $isEnabled; OriginalEnabled = $isEnabled
                Kind = if ($script:ZendExtensions -contains $id) { 'Zend' } else { 'PHP' }
                FileName = $dll.Name
            }
        }
    }
    return $result
}

function ConvertTo-BooleanOption([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Off' }
    if ($Value.Trim() -match '^(1|on|true|yes|stdout|stderr)$') { return 'On' }
    return 'Off'
}

function Read-EffectiveOptions([object]$Version, [string]$IniPath) {
    $statements = @()
    foreach ($definition in $script:OptionDefinitions) {
        $statements += "echo '$($definition.Name)=', ini_get('$($definition.Name)'), PHP_EOL;"
    }
    $code = [string]::Join(' ', $statements)
    $arguments = if ($IniPath -and (Test-Path -LiteralPath $IniPath -PathType Leaf)) {
        '-c "{0}" -r "{1}"' -f $IniPath, $code
    } else {
        '-n -r "{0}"' -f $code
    }
    try {
        $result = Invoke-Php $Version.PhpExe $arguments $Version.Home
        $values = @{}
        foreach ($line in ($result.Output -split "`r?`n")) {
            if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1].Trim()] = $matches[2].Trim() }
        }
        $missing = @($script:OptionDefinitions | Where-Object { -not $values.ContainsKey($_.Name) })
        return [pscustomobject]@{
            Success = ($result.ExitCode -eq 0 -and $missing.Count -eq 0)
            Values = $values
            Error = $result.Error.Trim()
        }
    } catch {
        return [pscustomobject]@{ Success = $false; Values = @{}; Error = $_.Exception.Message }
    }
}

function Get-OptionStates([object]$Version) {
    $read = Read-EffectiveOptions $Version $Version.IniPath
    $states = @{}
    foreach ($definition in $script:OptionDefinitions) {
        $value = $definition.Default
        if ($read.Values.ContainsKey($definition.Name)) {
            $candidate = [string]$read.Values[$definition.Name]
            if ($definition.Kind -eq 'Boolean') { $value = ConvertTo-BooleanOption $candidate }
            elseif (-not [string]::IsNullOrWhiteSpace($candidate)) { $value = $candidate }
        }
        $states[$definition.Name] = [pscustomobject]@{
            Name = $definition.Name; Kind = $definition.Kind
            Value = $value; OriginalValue = $value
        }
    }
    return $states
}

function Update-ExtensionIniText([string]$Text, [string]$NewLine, [hashtable]$States) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [regex]::Split($Text, "`r`n|`n|`r")) { [void]$lines.Add($line) }
    foreach ($state in @($States.Values | Sort-Object Id)) {
        $indexes = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $directive = Get-ExtensionDirective $lines[$i]
            if ($null -ne $directive -and $directive.Id -eq $state.Id) { [void]$indexes.Add($i) }
        }
        if ($state.Enabled) {
            $kind = if ($state.Kind -eq 'Zend') { 'zend_extension' } else { 'extension' }
            if ($indexes.Count) {
                $first = Get-ExtensionDirective $lines[$indexes[0]]
                $lines[$indexes[0]] = '{0}{1}={2}{3}' -f $first.Indent, $kind, $state.Id, $first.Tail
                for ($n = 1; $n -lt $indexes.Count; $n++) {
                    $duplicate = Get-ExtensionDirective $lines[$indexes[$n]]
                    if ($duplicate.Enabled) { $lines[$indexes[$n]] = ';' + $lines[$indexes[$n]] }
                }
            } else {
                $end = $lines.IndexOf($script:ExtensionBlockEnd)
                if ($end -lt 0) {
                    if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
                    [void]$lines.Add($script:ExtensionBlockStart); [void]$lines.Add($script:ExtensionBlockEnd); $end = $lines.Count - 1
                }
                $lines.Insert($end, "$kind=$($state.Id)")
            }
        } else {
            foreach ($index in $indexes) {
                $directive = Get-ExtensionDirective $lines[$index]
                if ($directive.Enabled) { $lines[$index] = ';' + $lines[$index] }
            }
        }
    }
    return [string]::Join($NewLine, $lines)
}

function Update-OptionIniText([string]$Text, [string]$NewLine, [hashtable]$States) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [regex]::Split($Text, "`r`n|`n|`r")) { [void]$lines.Add($line) }
    foreach ($state in @($States.Values | Where-Object { $_.Value -cne $_.OriginalValue } | Sort-Object Name)) {
        $escapedName = [regex]::Escape($state.Name)
        $indexes = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$escapedName\s*=") { [void]$indexes.Add($i) }
        }
        if ($indexes.Count) {
            $index = $indexes[$indexes.Count - 1]
            $match = [regex]::Match($lines[$index], "^(?<indent>\s*)$escapedName\s*=\s*[^;]*?(?<tail>\s*(?:;.*)?)$", 'IgnoreCase')
            $indent = if ($match.Success) { $match.Groups['indent'].Value } else { '' }
            $tail = if ($match.Success) { $match.Groups['tail'].Value } else { '' }
            $lines[$index] = '{0}{1} = {2}{3}' -f $indent, $state.Name, $state.Value, $tail
        } else {
            $end = $lines.IndexOf($script:OptionBlockEnd)
            if ($end -lt 0) {
                if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
                [void]$lines.Add($script:OptionBlockStart); [void]$lines.Add($script:OptionBlockEnd); $end = $lines.Count - 1
            }
            $lines.Insert($end, "$($state.Name) = $($state.Value)")
        }
    }
    return [string]::Join($NewLine, $lines)
}

function Ensure-Ini([object]$Version) {
    if (Test-Path -LiteralPath $Version.IniPath -PathType Leaf) { return $true }
    $template = if (Test-Path -LiteralPath $Version.DevelopmentIni -PathType Leaf) { $Version.DevelopmentIni }
        elseif (Test-Path -LiteralPath $Version.ProductionIni -PathType Leaf) { $Version.ProductionIni } else { '' }
    if (-not $template) { Show-Error "La versione '$($Version.Name)' non contiene un file php.ini o un modello utilizzabile."; return $false }
    $answer = [System.Windows.Forms.MessageBox]::Show("php.ini non e' presente.`r`n`r`nCrearlo da '$([IO.Path]::GetFileName($template))'?", 'Crea php.ini', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return $false }
    try { [IO.File]::Copy($template, $Version.IniPath, $false); return $true }
    catch { Show-Error "Impossibile creare php.ini.`r`n`r`n$($_.Exception.Message)"; return $false }
}

function Convert-IniSizeToBytes([string]$Value) {
    if ($Value -eq '-1') { return [decimal]-1 }
    $match = [regex]::Match($Value.Trim(), '^(?<number>\d+)\s*(?<unit>[KMG]?)$', 'IgnoreCase')
    if (-not $match.Success) { return $null }
    [decimal]$bytes = [decimal]::Parse($match.Groups['number'].Value, [Globalization.CultureInfo]::InvariantCulture)
    switch ($match.Groups['unit'].Value.ToUpperInvariant()) {
        'K' { $bytes *= 1024 }
        'M' { $bytes *= 1048576 }
        'G' { $bytes *= 1073741824 }
    }
    return $bytes
}

function Test-OptionValues([hashtable]$States) {
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($definition in $script:OptionDefinitions) {
        $state = $States[$definition.Name]
        $value = ([string]$state.Value).Trim()
        if ($definition.Kind -eq 'Boolean') {
            if ($value -notmatch '^(On|Off)$') { [void]$errors.Add("$($definition.Name): scegliere On oppure Off.") }
            continue
        }
        if ($definition.Kind -eq 'Integer') {
            [long]$number = 0
            if (-not [long]::TryParse($value, [ref]$number)) {
                [void]$errors.Add("$($definition.Name): inserire un numero intero.")
            } elseif ($number -eq -1 -and $definition.AllowMinusOne) {
                $state.Value = '-1'
            } elseif ($number -lt [long]$definition.Minimum) {
                [void]$errors.Add("$($definition.Name): il valore minimo e' $($definition.Minimum).")
            } else {
                $state.Value = $number.ToString([Globalization.CultureInfo]::InvariantCulture)
            }
            continue
        }
        if ($value -eq '-1' -and $definition.AllowMinusOne) {
            $state.Value = '-1'
        } elseif ($value -notmatch '^\d+\s*[KMG]?$') {
            [void]$errors.Add("$($definition.Name): usare un numero eventualmente seguito da K, M o G (esempio: 128M).")
        } else {
            $state.Value = ($value -replace '\s+', '').ToUpperInvariant()
        }
    }
    if ($errors.Count -eq 0) {
        $post = Convert-IniSizeToBytes $States['post_max_size'].Value
        $upload = Convert-IniSizeToBytes $States['upload_max_filesize'].Value
        $memory = Convert-IniSizeToBytes $States['memory_limit'].Value
        if ($post -gt 0 -and $upload -gt 0 -and $post -le $upload) {
            [void]$errors.Add('post_max_size deve essere maggiore di upload_max_filesize.')
        }
        if ($memory -ge 0 -and $post -gt 0 -and $memory -lt $post) {
            [void]$warnings.Add('memory_limit e'' inferiore a post_max_size. PHP consiglia un limite di memoria maggiore della dimensione POST.')
        }
    }
    return [pscustomobject]@{ Success = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

function Test-Configuration([object]$Version, [string]$IniPath, [hashtable]$ExtensionStates, [hashtable]$OptionStates) {
    $result = Invoke-Php $Version.PhpExe ('-c "{0}" -m' -f $IniPath) $Version.Home
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($result.ExitCode -ne 0) { [void]$errors.Add("php.exe ha restituito il codice $($result.ExitCode).") }
    if ($result.Error -match '(?im)PHP Startup:|Unable to load dynamic library') { [void]$errors.Add($result.Error.Trim()) }
    $modules = @($result.Output -split "`r?`n" | ForEach-Object { $_.Trim().ToLowerInvariant() })
    foreach ($state in @($ExtensionStates.Values | Where-Object Enabled)) {
        $expected = if ($state.Id -eq 'opcache') { 'zend opcache' } else { $state.Id }
        if ($modules -notcontains $expected) { [void]$errors.Add("L'estensione '$($state.Id)' non compare tra i moduli caricati.") }
    }
    $effective = Read-EffectiveOptions $Version $IniPath
    if (-not $effective.Success) {
        [void]$errors.Add("PHP non ha restituito tutte le opzioni attese.`r`n$($effective.Error)")
    } else {
        foreach ($state in @($OptionStates.Values | Where-Object { $_.Value -cne $_.OriginalValue })) {
            $actual = [string]$effective.Values[$state.Name]
            $matchesValue = if ($state.Kind -eq 'Boolean') {
                (ConvertTo-BooleanOption $actual) -eq $state.Value
            } elseif ($state.Kind -eq 'Integer') {
                $actual.Trim() -eq $state.Value
            } else {
                $actual.Trim().ToUpperInvariant() -eq $state.Value.ToUpperInvariant()
            }
            if (-not $matchesValue) { [void]$errors.Add("L'opzione '$($state.Name)' non ha assunto il valore richiesto '$($state.Value)'.") }
        }
    }
    return [pscustomobject]@{ Success = ($errors.Count -eq 0); Message = [string]::Join("`r`n", $errors) }
}

function Save-Configuration([object]$Version, [hashtable]$ExtensionStates, [hashtable]$OptionStates) {
    if (-not (Ensure-Ini $Version)) { return $false }
    $doc = Read-TextDocument $Version.IniPath
    $updated = Update-ExtensionIniText $doc.Text $doc.NewLine $ExtensionStates
    $updated = Update-OptionIniText $updated $doc.NewLine $OptionStates
    if ($updated -ceq $doc.Text) {
        [void][System.Windows.Forms.MessageBox]::Show('Non ci sono modifiche da salvare.', 'LiteWAMP', 'OK', 'Information')
        return $true
    }
    $temporary = Join-Path $Version.Home ('.litewamp-php-{0}.ini' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-TextDocument $temporary $updated $doc
        $validation = Test-Configuration $Version $temporary $ExtensionStates $OptionStates
        if (-not $validation.Success) {
            Show-Error "Le modifiche non sono state applicate perche' la verifica PHP non e' riuscita.`r`n`r`n$($validation.Message)"
            return $false
        }
        $backup = $Version.IniPath + '.litewamp.bak'
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { [IO.File]::Copy($Version.IniPath, $backup, $false) }
        try { [IO.File]::Replace($temporary, $Version.IniPath, $null) }
        catch { [IO.File]::Copy($temporary, $Version.IniPath, $true); [IO.File]::Delete($temporary) }
        return $true
    } catch { Show-Error "Impossibile salvare la configurazione.`r`n`r`n$($_.Exception.Message)"; return $false }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Restore-Configuration([object]$Version) {
    $backup = $Version.IniPath + '.litewamp.bak'
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show('Nessun backup disponibile per questa versione.', 'LiteWAMP', 'OK', 'Information'); return $false
    }
    if ([System.Windows.Forms.MessageBox]::Show('Ripristinare il php.ini originale? Le impostazioni attuali verranno sostituite.', 'Ripristina backup', 'YesNo', 'Warning') -ne 'Yes') { return $false }
    try { [IO.File]::Copy($backup, $Version.IniPath, $true); return $true }
    catch { Show-Error "Impossibile ripristinare il backup.`r`n`r`n$($_.Exception.Message)"; return $false }
}

$versions = @(Get-Versions)
if (-not $versions.Count) { Show-Error "Nessuna versione PHP valida trovata in:`r`n$PhpRoot"; exit 1 }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LiteWAMP - Configurazione PHP'; $form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(860, 660); $form.MinimumSize = New-Object Drawing.Size(720, 540)
$form.AutoScaleMode = 'Dpi'; $form.Font = New-Object Drawing.Font('Segoe UI', 9)

$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 4
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 58)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 34)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 62)))

$top = New-Object Windows.Forms.TableLayoutPanel
$top.Dock = 'Fill'; $top.Padding = New-Object Windows.Forms.Padding(12, 12, 12, 6); $top.ColumnCount = 2; $top.RowCount = 1
[void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 105)))
[void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$versionLabel = New-Object Windows.Forms.Label; $versionLabel.Text = 'Versione PHP:'; $versionLabel.Dock = 'Fill'; $versionLabel.TextAlign = 'MiddleLeft'
$combo = New-Object Windows.Forms.ComboBox; $combo.Dock = 'Fill'; $combo.DropDownStyle = 'DropDownList'; $combo.DisplayMember = 'DisplayName'
$top.Controls.Add($versionLabel, 0, 0); $top.Controls.Add($combo, 1, 0)

$status = New-Object Windows.Forms.Label
$status.Dock = 'Fill'; $status.Padding = New-Object Windows.Forms.Padding(14, 5, 14, 5); $status.ForeColor = 'DimGray'

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Margin = New-Object Windows.Forms.Padding(12, 0, 12, 0)
$extensionsTab = New-Object Windows.Forms.TabPage; $extensionsTab.Text = 'Estensioni'; $extensionsTab.Padding = New-Object Windows.Forms.Padding(8)
$optionsTab = New-Object Windows.Forms.TabPage; $optionsTab.Text = 'Opzioni principali'; $optionsTab.Padding = New-Object Windows.Forms.Padding(8)
[void]$tabs.TabPages.Add($extensionsTab); [void]$tabs.TabPages.Add($optionsTab)

$extensionLayout = New-Object Windows.Forms.TableLayoutPanel
$extensionLayout.Dock = 'Fill'; $extensionLayout.ColumnCount = 1; $extensionLayout.RowCount = 3
[void]$extensionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 38)))
[void]$extensionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$extensionLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 42)))
$searchPanel = New-Object Windows.Forms.TableLayoutPanel; $searchPanel.Dock = 'Fill'; $searchPanel.ColumnCount = 2; $searchPanel.RowCount = 1
[void]$searchPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 72)))
[void]$searchPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$searchLabel = New-Object Windows.Forms.Label; $searchLabel.Text = 'Cerca:'; $searchLabel.Dock = 'Fill'; $searchLabel.TextAlign = 'MiddleLeft'
$search = New-Object Windows.Forms.TextBox; $search.Dock = 'Fill'
$searchPanel.Controls.Add($searchLabel, 0, 0); $searchPanel.Controls.Add($search, 1, 0)
$list = New-Object Windows.Forms.ListView; $list.Dock = 'Fill'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.GridLines = $true; $list.View = 'Details'
[void]$list.Columns.Add('Estensione', 210); [void]$list.Columns.Add('Stato', 115); [void]$list.Columns.Add('Tipo', 70); [void]$list.Columns.Add('File', 230)
$extensionButtons = New-Object Windows.Forms.FlowLayoutPanel; $extensionButtons.Dock = 'Fill'; $extensionButtons.FlowDirection = 'RightToLeft'; $extensionButtons.Padding = New-Object Windows.Forms.Padding(0, 6, 0, 0)
$common = New-Object Windows.Forms.Button; $common.Text = 'Seleziona comuni'; $common.Size = New-Object Drawing.Size(130, 30)
$extensionButtons.Controls.Add($common)
$extensionLayout.Controls.Add($searchPanel, 0, 0); $extensionLayout.Controls.Add($list, 0, 1); $extensionLayout.Controls.Add($extensionButtons, 0, 2)
$extensionsTab.Controls.Add($extensionLayout)

$optionsPanel = New-Object Windows.Forms.Panel; $optionsPanel.Dock = 'Fill'; $optionsPanel.AutoScroll = $true
$optionsLayout = New-Object Windows.Forms.TableLayoutPanel
$optionsLayout.Dock = 'Top'; $optionsLayout.AutoSize = $true; $optionsLayout.ColumnCount = 3; $optionsLayout.RowCount = $script:OptionDefinitions.Count + 1
[void]$optionsLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 190)))
[void]$optionsLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 155)))
[void]$optionsLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$nameHeader = New-Object Windows.Forms.Label; $nameHeader.Text = 'Direttiva'; $nameHeader.Font = New-Object Drawing.Font($form.Font, 'Bold'); $nameHeader.Dock = 'Fill'; $nameHeader.Padding = New-Object Windows.Forms.Padding(3, 5, 3, 5)
$valueHeader = New-Object Windows.Forms.Label; $valueHeader.Text = 'Valore'; $valueHeader.Font = New-Object Drawing.Font($form.Font, 'Bold'); $valueHeader.Dock = 'Fill'; $valueHeader.Padding = New-Object Windows.Forms.Padding(3, 5, 3, 5)
$descriptionHeader = New-Object Windows.Forms.Label; $descriptionHeader.Text = 'Descrizione'; $descriptionHeader.Font = New-Object Drawing.Font($form.Font, 'Bold'); $descriptionHeader.Dock = 'Fill'; $descriptionHeader.Padding = New-Object Windows.Forms.Padding(3, 5, 3, 5)
$optionsLayout.Controls.Add($nameHeader, 0, 0); $optionsLayout.Controls.Add($valueHeader, 1, 0); $optionsLayout.Controls.Add($descriptionHeader, 2, 0)
$row = 1
foreach ($definition in $script:OptionDefinitions) {
    [void]$optionsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 42)))
    $label = New-Object Windows.Forms.Label; $label.Text = $definition.Name; $label.Dock = 'Fill'; $label.TextAlign = 'MiddleLeft'; $label.Padding = New-Object Windows.Forms.Padding(3)
    if ($definition.Kind -eq 'Boolean') {
        $control = New-Object Windows.Forms.CheckBox; $control.Text = 'Attiva'; $control.Dock = 'Fill'; $control.Padding = New-Object Windows.Forms.Padding(3)
        $control.Add_CheckedChanged({ if (-not $script:Loading) { Sync-OptionStatesFromControls; Update-DirtyState } })
    } else {
        $control = New-Object Windows.Forms.TextBox; $control.Dock = 'Fill'; $control.Margin = New-Object Windows.Forms.Padding(3, 8, 12, 7)
        $control.Add_TextChanged({ if (-not $script:Loading) { Sync-OptionStatesFromControls; Update-DirtyState } })
    }
    $description = New-Object Windows.Forms.Label; $description.Text = $definition.Description; $description.Dock = 'Fill'; $description.TextAlign = 'MiddleLeft'; $description.AutoEllipsis = $true; $description.Padding = New-Object Windows.Forms.Padding(3)
    $script:OptionControls[$definition.Name] = $control
    $optionsLayout.Controls.Add($label, 0, $row); $optionsLayout.Controls.Add($control, 1, $row); $optionsLayout.Controls.Add($description, 2, $row)
    $row++
}
$optionsPanel.Controls.Add($optionsLayout); $optionsTab.Controls.Add($optionsPanel)

$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'; $buttons.Padding = New-Object Windows.Forms.Padding(9, 12, 9, 9); $buttons.FlowDirection = 'RightToLeft'
$close = New-Object Windows.Forms.Button; $close.Text = 'Chiudi'; $close.Size = New-Object Drawing.Size(90, 30)
$save = New-Object Windows.Forms.Button; $save.Text = 'Salva e verifica'; $save.Size = New-Object Drawing.Size(130, 30)
$restore = New-Object Windows.Forms.Button; $restore.Text = 'Ripristina backup'; $restore.Size = New-Object Drawing.Size(130, 30)
$buttons.Controls.AddRange(@($close, $save, $restore))

$root.Controls.Add($top, 0, 0); $root.Controls.Add($status, 0, 1); $root.Controls.Add($tabs, 0, 2); $root.Controls.Add($buttons, 0, 3)
$form.Controls.Add($root); $form.CancelButton = $close

function Sync-OptionStatesFromControls {
    if ($script:OptionStates.Count -eq 0) { return }
    foreach ($definition in $script:OptionDefinitions) {
        $control = $script:OptionControls[$definition.Name]
        if ($definition.Kind -eq 'Boolean') {
            $script:OptionStates[$definition.Name].Value = if ($control.Checked) { 'On' } else { 'Off' }
        } else {
            $script:OptionStates[$definition.Name].Value = $control.Text.Trim()
        }
    }
}

function Update-Status {
    $suffix = if ($script:IsDirty) { ' - Modifiche non salvate' } else { '' }
    $status.Text = $script:StatusBase + $suffix
    $form.Text = 'LiteWAMP - Configurazione PHP' + $(if ($script:IsDirty) { ' *' } else { '' })
    $save.Enabled = $script:IsDirty -and $null -ne $script:Version
}

function Update-DirtyState {
    $dirty = $false
    foreach ($state in $script:ExtensionStates.Values) {
        if ($state.Enabled -ne $state.OriginalEnabled) { $dirty = $true; break }
    }
    if (-not $dirty) {
        foreach ($state in $script:OptionStates.Values) {
            if ($state.Value -cne $state.OriginalValue) { $dirty = $true; break }
        }
    }
    $script:IsDirty = $dirty
    Update-Status
}

function Refresh-ExtensionList {
    $filter = $search.Text.Trim(); $script:Loading = $true; $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($state in @($script:ExtensionStates.Values | Sort-Object Id)) {
            if ($filter -and $state.Id.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $item = New-Object Windows.Forms.ListViewItem($state.Id); $item.Name = $state.Id; $item.Checked = $state.Enabled
            [void]$item.SubItems.Add($(if ($state.Enabled) { 'Attiva' } else { 'Disponibile' })); [void]$item.SubItems.Add($state.Kind); [void]$item.SubItems.Add($state.FileName); [void]$list.Items.Add($item)
        }
    } finally { $list.EndUpdate(); $script:Loading = $false }
}

function Refresh-OptionControls {
    $script:Loading = $true
    try {
        foreach ($definition in $script:OptionDefinitions) {
            $state = $script:OptionStates[$definition.Name]
            $control = $script:OptionControls[$definition.Name]
            if ($definition.Kind -eq 'Boolean') { $control.Checked = $state.Value -eq 'On' }
            else { $control.Text = $state.Value }
        }
    } finally { $script:Loading = $false }
}

function Load-Version([object]$Version) {
    if ($null -eq $Version) { return }
    $script:Version = $Version; $script:SelectedIndex = $combo.SelectedIndex
    $script:ExtensionStates = Get-ExtensionStates $Version
    $script:OptionStates = Get-OptionStates $Version
    $script:IsDirty = $false
    $iniStatus = if (Test-Path -LiteralPath $Version.IniPath -PathType Leaf) { 'php.ini presente' } else { "php.ini assente: verra' proposto di crearlo al salvataggio" }
    $script:StatusBase = "$($script:ExtensionStates.Count) estensioni disponibili - $iniStatus. Effetto al prossimo avvio di PHP."
    $common.Enabled = $script:ExtensionStates.Count -gt 0
    $restore.Enabled = Test-Path -LiteralPath ($Version.IniPath + '.litewamp.bak') -PathType Leaf
    Refresh-ExtensionList; Refresh-OptionControls; Update-Status
}

function Save-CurrentConfiguration([bool]$ShowSuccess) {
    Sync-OptionStatesFromControls
    $optionCheck = Test-OptionValues $script:OptionStates
    if (-not $optionCheck.Success) {
        Show-Error ([string]::Join("`r`n", $optionCheck.Errors))
        return $false
    }
    if ($optionCheck.Warnings.Count -gt 0) {
        $warningText = [string]::Join("`r`n", $optionCheck.Warnings)
        $answer = [Windows.Forms.MessageBox]::Show("$warningText`r`n`r`nSalvare comunque?", 'Verifica opzioni PHP', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return $false }
    }
    $form.UseWaitCursor = $true; $save.Enabled = $false
    try {
        if (-not (Save-Configuration $script:Version $script:ExtensionStates $script:OptionStates)) { return $false }
        if ($ShowSuccess) {
            [void][Windows.Forms.MessageBox]::Show("Configurazione salvata e verificata. Sara' attiva al prossimo avvio di PHP.", 'LiteWAMP', 'OK', 'Information')
        }
        return $true
    } finally {
        $form.UseWaitCursor = $false
        Update-Status
    }
}

function Revert-VersionSelection {
    $script:Loading = $true
    try { $combo.SelectedIndex = $script:SelectedIndex }
    finally { $script:Loading = $false }
}

$list.Add_ItemCheck({ param($sender, $eventArgs)
    if ($script:Loading -or $eventArgs.Index -lt 0) { return }
    $id = $list.Items[$eventArgs.Index].Name
    if ($script:ExtensionStates.ContainsKey($id)) {
        $script:ExtensionStates[$id].Enabled = $eventArgs.NewValue -eq 'Checked'
        $list.Items[$eventArgs.Index].SubItems[1].Text = if ($script:ExtensionStates[$id].Enabled) { 'Attiva' } else { 'Disponibile' }
        Update-DirtyState
    }
})
$search.Add_TextChanged({ Refresh-ExtensionList })
$common.Add_Click({
    foreach ($state in $script:ExtensionStates.Values) {
        if ($script:CommonExtensions -contains $state.Id) { $state.Enabled = $true }
    }
    Refresh-ExtensionList; Update-DirtyState
})
$combo.Add_SelectedIndexChanged({
    if ($script:Loading -or $null -eq $combo.SelectedItem) { return }
    if ($null -ne $script:Version -and $combo.SelectedItem.Name -ne $script:Version.Name -and $script:IsDirty) {
        $answer = [Windows.Forms.MessageBox]::Show('Salvare le modifiche prima di cambiare versione PHP?', 'Modifiche non salvate', 'YesNoCancel', 'Question')
        if ($answer -eq 'Cancel') { Revert-VersionSelection; return }
        if ($answer -eq 'Yes' -and -not (Save-CurrentConfiguration $false)) { Revert-VersionSelection; return }
    }
    Load-Version $combo.SelectedItem
})
$save.Add_Click({
    if (Save-CurrentConfiguration $true) { Load-Version $script:Version }
})
$restore.Add_Click({
    if (Restore-Configuration $script:Version) {
        Load-Version $script:Version
        [void][Windows.Forms.MessageBox]::Show('Backup iniziale ripristinato.', 'LiteWAMP', 'OK', 'Information')
    }
})
$close.Add_Click({ $form.Close() })
$form.Add_FormClosing({ param($sender, $eventArgs)
    if (-not $script:IsDirty) { return }
    $answer = [Windows.Forms.MessageBox]::Show('Salvare le modifiche prima di chiudere?', 'Modifiche non salvate', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { $eventArgs.Cancel = $true; return }
    if ($answer -eq 'Yes' -and -not (Save-CurrentConfiguration $false)) { $eventArgs.Cancel = $true }
})

foreach ($version in $versions) { [void]$combo.Items.Add($version) }
$configured = Get-ConfiguredVersion; $selected = 0
for ($i = 0; $i -lt $versions.Count; $i++) { if ($versions[$i].Name -eq $configured) { $selected = $i; break } }
$combo.SelectedIndex = $selected

if ($SmokeTest) {
    $form.Dispose()
    exit 0
}
[void][Windows.Forms.Application]::Run($form)
