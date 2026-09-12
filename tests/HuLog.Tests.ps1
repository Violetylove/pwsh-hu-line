# HuLog — the diagnostic log. It exists so that field failures can be READ
# instead of guessed about, so these tests pin the parts that matter: it writes
# where told, it can be turned off, it round-trips non-ASCII (Chinese console
# paths show up in these lines), and the identity fingerprint / error dump carry
# the facts needed to settle a class-identity question.

function New-HuLogPath {
    return Join-Path ([System.IO.Path]::GetTempPath()) ('hu-log-' + [guid]::NewGuid().ToString('N') + '.log')
}

function Read-HuLog([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

It 'HuLog writes timestamped, tagged lines and round-trips non-ASCII' {
    $p = New-HuLogPath
    $wasOn = [HuLog]::On; $wasPath = [HuLog]::Path
    try {
        [HuLog]::Init($p)
        [HuLog]::Write('info', 'test', 'hello 世界')
        Assert-True ([System.IO.File]::Exists($p)) 'log file created'
        $text = Read-HuLog $p
        Assert-Contains $text 'hello 世界'
        Assert-Contains $text '[info ]'
        Assert-Contains $text 'test'
        Assert-True ([regex]::IsMatch($text, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}')) 'timestamp prefix'
    } finally {
        [HuLog]::On = $wasOn; [HuLog]::Path = $wasPath
        Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
    }
}

It 'HU_LINE_LOG=0 turns the log off completely' {
    $wasOn = [HuLog]::On; $wasPath = [HuLog]::Path; $wasEnv = $env:HU_LINE_LOG
    try {
        $env:HU_LINE_LOG = '0'
        [HuLog]::Init('')
        Assert-True (-not [HuLog]::On) 'logging disabled'
        Assert-True ([string]::IsNullOrEmpty([HuLog]::Path)) 'no path when disabled'
        [HuLog]::Write('info', 'test', 'must not appear anywhere')
    } finally {
        $env:HU_LINE_LOG = $wasEnv
        [HuLog]::On = $wasOn; [HuLog]::Path = $wasPath
    }
}

It 'HuLog.Identity fingerprints every module class' {
    $id = [HuLog]::Identity()
    Assert-Contains $id 'HuLineBuffer='
    Assert-Contains $id 'HuCompletionApplier='
    Assert-Contains $id 'HuRegion='
    Assert-Contains $id 'HuStyle='
    Assert-NotContains $id 'unavailable'
}

It 'HuLog.Error dumps message, FQID, position and script stack' {
    $p = New-HuLogPath
    $wasOn = [HuLog]::On; $wasPath = [HuLog]::Path
    try {
        [HuLog]::Init($p)
        $rec = $null
        try { throw 'boom-marker' } catch { $rec = $_ }
        [HuLog]::Error('test', 'context-x', $rec)
        $text = Read-HuLog $p
        Assert-Contains $text 'context-x: boom-marker'
        Assert-Contains $text 'FQID :'
        Assert-Contains $text 'STACK:'
    } finally {
        [HuLog]::On = $wasOn; [HuLog]::Path = $wasPath
        Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
    }
}

It 'HuLog.Environment reports encoding and loaded module copies' {
    $envLine = [HuLog]::Environment()
    Assert-Contains $envLine 'encoding='
    Assert-Contains $envLine 'modules=['
}

# Rotation used to be broken in a way only a real run showed: the size probe was
# written as `Get-Item -LiteralPath [HuLog]::Path`, and in ARGUMENT mode
# PowerShell does not evaluate `[Type]::Member` — it passes the literal text, so
# every load printed "Cannot find a provider with the name '[HuLog]'" and the log
# never rotated. $Error.Count catches that class of non-terminating noise.
It 'HuLog.Rotate moves an oversized log aside and raises no error' {
    $p = New-HuLogPath
    $wasOn = [HuLog]::On; $wasPath = [HuLog]::Path; $wasMax = [HuLog]::MaxBytes
    try {
        [System.IO.File]::WriteAllText($p, ('x' * 500), [System.Text.UTF8Encoding]::new($false))
        [HuLog]::MaxBytes = 100
        $Error.Clear()
        [HuLog]::Init($p)
        Assert-Equal $Error.Count 0 ('no error raised, got: ' + (($Error | ForEach-Object { $_.Exception.Message }) -join ' | '))
        Assert-True ([System.IO.File]::Exists($p + '.1')) 'oversized log moved to .1'
        if ([System.IO.File]::Exists($p)) { Assert-True ((Get-Item -LiteralPath $p).Length -eq 0) 'fresh log is empty' }
    } finally {
        [HuLog]::MaxBytes = $wasMax; [HuLog]::On = $wasOn; [HuLog]::Path = $wasPath
        Remove-Item -LiteralPath $p, ($p + '.1') -ErrorAction SilentlyContinue
    }
}
