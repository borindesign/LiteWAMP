[CmdletBinding()]
param(
    [string]$PhpRoot = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'PHP'),
    [switch]$SmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:States = @{}
$script:Version = $null
$script:Loading = $false
$script:BlockStart = '; BEGIN LiteWAMP managed extensions'
$script:BlockEnd = '; END LiteWAMP managed extensions'
$script:ZendExtensions = @('opcache', 'xdebug')
$script:CommonExtensions = @('curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'pdo_sqlite', 'sodium', 'sqlite3', 'zip')

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'LiteWAMP - Estensioni PHP', 'OK', 'Error')
}

function Get-ExtensionId([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $id = $Value.Trim().Trim('"').Trim("'").Replace('/', '\')
    $id = [System.IO.Path]::GetFileName($id).ToLowerInvariant()
    if ($id.StartsWith('php_')) { $id = $id.Substring(4) }
    if ($id.EndsWith('.dll')) { $id = $id.Substring(0, $id.Length - 4) }
    return $id
}

function Get-Directive([string]$Line) {
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

function Get-States([object]$Version) {
    $enabled = @{}
    if (Test-Path -LiteralPath $Version.IniPath -PathType Leaf) {
        $doc = Read-TextDocument $Version.IniPath
        foreach ($line in [regex]::Split($doc.Text, "`r`n|`n|`r")) {
            $directive = Get-Directive $line
            if ($null -ne $directive -and $directive.Enabled) { $enabled[$directive.Id] = $true }
        }
    }
    $result = @{}
    if (Test-Path -LiteralPath $Version.ExtPath -PathType Container) {
        foreach ($dll in Get-ChildItem -LiteralPath $Version.ExtPath -Filter 'php_*.dll' -File -ErrorAction SilentlyContinue) {
            $id = Get-ExtensionId $dll.Name
            if (-not $id) { continue }
            $result[$id] = [pscustomobject]@{
                Id = $id; Enabled = $enabled.ContainsKey($id)
                Kind = if ($script:ZendExtensions -contains $id) { 'Zend' } else { 'PHP' }
                FileName = $dll.Name
            }
        }
    }
    return $result
}

function Update-IniText([string]$Text, [string]$NewLine, [hashtable]$States) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [regex]::Split($Text, "`r`n|`n|`r")) { [void]$lines.Add($line) }
    foreach ($state in @($States.Values | Sort-Object Id)) {
        $indexes = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $directive = Get-Directive $lines[$i]
            if ($null -ne $directive -and $directive.Id -eq $state.Id) { [void]$indexes.Add($i) }
        }
        if ($state.Enabled) {
            $kind = if ($state.Kind -eq 'Zend') { 'zend_extension' } else { 'extension' }
            if ($indexes.Count) {
                $first = Get-Directive $lines[$indexes[0]]
                $lines[$indexes[0]] = '{0}{1}={2}{3}' -f $first.Indent, $kind, $state.Id, $first.Tail
                for ($n = 1; $n -lt $indexes.Count; $n++) {
                    $duplicate = Get-Directive $lines[$indexes[$n]]
                    if ($duplicate.Enabled) { $lines[$indexes[$n]] = ';' + $lines[$indexes[$n]] }
                }
            } else {
                $end = $lines.IndexOf($script:BlockEnd)
                if ($end -lt 0) {
                    if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
                    [void]$lines.Add($script:BlockStart); [void]$lines.Add($script:BlockEnd); $end = $lines.Count - 1
                }
                $lines.Insert($end, "$kind=$($state.Id)")
            }
        } else {
            foreach ($index in $indexes) {
                $directive = Get-Directive $lines[$index]
                if ($directive.Enabled) { $lines[$index] = ';' + $lines[$index] }
            }
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

function Test-Configuration([object]$Version, [string]$IniPath, [hashtable]$States) {
    $result = Invoke-Php $Version.PhpExe ('-c "{0}" -m' -f $IniPath) $Version.Home
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($result.ExitCode -ne 0) { [void]$errors.Add("php.exe ha restituito il codice $($result.ExitCode).") }
    if ($result.Error -match '(?im)PHP Startup:|Unable to load dynamic library') { [void]$errors.Add($result.Error.Trim()) }
    $modules = @($result.Output -split "`r?`n" | ForEach-Object { $_.Trim().ToLowerInvariant() })
    foreach ($state in @($States.Values | Where-Object Enabled)) {
        $expected = if ($state.Id -eq 'opcache') { 'zend opcache' } else { $state.Id }
        if ($modules -notcontains $expected) { [void]$errors.Add("L'estensione '$($state.Id)' non compare tra i moduli caricati.") }
    }
    return [pscustomobject]@{ Success = ($errors.Count -eq 0); Message = [string]::Join("`r`n", $errors) }
}

function Save-Configuration([object]$Version, [hashtable]$States) {
    if (-not (Ensure-Ini $Version)) { return $false }
    $doc = Read-TextDocument $Version.IniPath
    $updated = Update-IniText $doc.Text $doc.NewLine $States
    if ($updated -ceq $doc.Text) {
        [void][System.Windows.Forms.MessageBox]::Show('Non ci sono modifiche da salvare.', 'LiteWAMP', 'OK', 'Information')
        return $true
    }
    $temporary = Join-Path $Version.Home ('.litewamp-php-{0}.ini' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-TextDocument $temporary $updated $doc
        $validation = Test-Configuration $Version $temporary $States
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
$form.Text = 'LiteWAMP - Estensioni PHP'; $form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(760, 610); $form.MinimumSize = New-Object Drawing.Size(680, 500)
$form.AutoScaleMode = 'Dpi'; $form.Font = New-Object Drawing.Font('Segoe UI', 9)

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = 'Top'; $top.Height = 92; $top.Padding = New-Object Windows.Forms.Padding(12, 12, 12, 6); $top.ColumnCount = 2; $top.RowCount = 2
[void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 105)))
[void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$versionLabel = New-Object Windows.Forms.Label; $versionLabel.Text = 'Versione PHP:'; $versionLabel.Dock = 'Fill'; $versionLabel.TextAlign = 'MiddleLeft'
$combo = New-Object Windows.Forms.ComboBox; $combo.Dock = 'Fill'; $combo.DropDownStyle = 'DropDownList'; $combo.DisplayMember = 'DisplayName'
$searchLabel = New-Object Windows.Forms.Label; $searchLabel.Text = 'Cerca:'; $searchLabel.Dock = 'Fill'; $searchLabel.TextAlign = 'MiddleLeft'
$search = New-Object Windows.Forms.TextBox; $search.Dock = 'Fill'
$top.Controls.Add($versionLabel, 0, 0); $top.Controls.Add($combo, 1, 0); $top.Controls.Add($searchLabel, 0, 1); $top.Controls.Add($search, 1, 1)

$status = New-Object Windows.Forms.Label; $status.Dock = 'Top'; $status.Height = 34; $status.Padding = New-Object Windows.Forms.Padding(14, 5, 14, 5); $status.ForeColor = 'DimGray'
$list = New-Object Windows.Forms.ListView; $list.Dock = 'Fill'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.GridLines = $true; $list.View = 'Details'
[void]$list.Columns.Add('Estensione', 230); [void]$list.Columns.Add('Stato', 120); [void]$list.Columns.Add('Tipo', 75); [void]$list.Columns.Add('File', 220)
$center = New-Object Windows.Forms.Panel; $center.Dock = 'Fill'; $center.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0); $center.Controls.Add($list)

$buttons = New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock = 'Bottom'; $buttons.Height = 62; $buttons.Padding = New-Object Windows.Forms.Padding(9, 12, 9, 9); $buttons.FlowDirection = 'RightToLeft'
$close = New-Object Windows.Forms.Button; $close.Text = 'Chiudi'; $close.Size = New-Object Drawing.Size(90, 30)
$save = New-Object Windows.Forms.Button; $save.Text = 'Salva e verifica'; $save.Size = New-Object Drawing.Size(130, 30)
$restore = New-Object Windows.Forms.Button; $restore.Text = 'Ripristina backup'; $restore.Size = New-Object Drawing.Size(130, 30)
$common = New-Object Windows.Forms.Button; $common.Text = 'Seleziona comuni'; $common.Size = New-Object Drawing.Size(130, 30)
$buttons.Controls.AddRange(@($close, $save, $restore, $common))
$form.Controls.Add($center); $form.Controls.Add($status); $form.Controls.Add($top); $form.Controls.Add($buttons); $form.CancelButton = $close

function Refresh-List {
    $filter = $search.Text.Trim(); $script:Loading = $true; $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($state in @($script:States.Values | Sort-Object Id)) {
            if ($filter -and $state.Id.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $item = New-Object Windows.Forms.ListViewItem($state.Id); $item.Name = $state.Id; $item.Checked = $state.Enabled
            [void]$item.SubItems.Add($(if ($state.Enabled) { 'Attiva' } else { 'Disponibile' })); [void]$item.SubItems.Add($state.Kind); [void]$item.SubItems.Add($state.FileName); [void]$list.Items.Add($item)
        }
    } finally { $list.EndUpdate(); $script:Loading = $false }
}

function Load-Version {
    if ($null -eq $combo.SelectedItem) { return }
    $script:Version = $combo.SelectedItem; $script:States = Get-States $script:Version
    $iniStatus = if (Test-Path -LiteralPath $script:Version.IniPath -PathType Leaf) { 'php.ini presente' } else { "php.ini assente: verra' proposto di crearlo al salvataggio" }
    $status.Text = "$($script:States.Count) estensioni disponibili - $iniStatus. Effetto al prossimo avvio di PHP."
    $save.Enabled = $script:States.Count -gt 0; $common.Enabled = $save.Enabled
    $restore.Enabled = Test-Path -LiteralPath ($script:Version.IniPath + '.litewamp.bak') -PathType Leaf
    Refresh-List
}

$list.Add_ItemCheck({ param($sender, $eventArgs)
    if ($script:Loading -or $eventArgs.Index -lt 0) { return }
    $id = $list.Items[$eventArgs.Index].Name
    if ($script:States.ContainsKey($id)) {
        $script:States[$id].Enabled = $eventArgs.NewValue -eq 'Checked'
        $list.Items[$eventArgs.Index].SubItems[1].Text = if ($script:States[$id].Enabled) { 'Attiva' } else { 'Disponibile' }
    }
})
$combo.Add_SelectedIndexChanged({ Load-Version }); $search.Add_TextChanged({ Refresh-List })
$common.Add_Click({ foreach ($state in $script:States.Values) { if ($script:CommonExtensions -contains $state.Id) { $state.Enabled = $true } }; Refresh-List })
$save.Add_Click({
    $form.UseWaitCursor = $true; $save.Enabled = $false
    try {
        if (Save-Configuration $script:Version $script:States) {
            $script:States = Get-States $script:Version; Refresh-List; $restore.Enabled = $true
            [void][Windows.Forms.MessageBox]::Show("Configurazione salvata e verificata. Sara' attiva al prossimo avvio di PHP.", 'LiteWAMP', 'OK', 'Information')
        }
    } finally { $form.UseWaitCursor = $false; $save.Enabled = $script:States.Count -gt 0 }
})
$restore.Add_Click({ if (Restore-Configuration $script:Version) { $script:States = Get-States $script:Version; Refresh-List; [void][Windows.Forms.MessageBox]::Show('Backup iniziale ripristinato.', 'LiteWAMP', 'OK', 'Information') } })
$close.Add_Click({ $form.Close() })

foreach ($version in $versions) { [void]$combo.Items.Add($version) }
$configured = Get-ConfiguredVersion; $selected = 0
for ($i = 0; $i -lt $versions.Count; $i++) { if ($versions[$i].Name -eq $configured) { $selected = $i; break } }
$combo.SelectedIndex = $selected

if ($SmokeTest) {
    $form.Dispose()
    exit 0
}
[void][Windows.Forms.Application]::Run($form)
