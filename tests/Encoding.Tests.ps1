# HuConsoleEncoding — the console output code page on this machine is GB2312
# (CP936), which cannot represent prompt glyphs such as starship's ❯ (U+276F);
# .NET silently writes '?' for them. These tests pin the guard that makes the
# editor's write path lossless. The real-console proof (screen buffer readback)
# lives in tests/console-encoding.ps1.

function Get-ConsoleEncodingOrNull {
    try { return [Console]::OutputEncoding } catch { return $null }
}

It 'HuConsoleEncoding.BeginUtf8 switches [Console]::Out to a lossless encoder' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }   # no console attached: not applicable
    $snapshot = [HuConsoleEncoding]::BeginUtf8()
    try {
        Assert-Equal ([Console]::OutputEncoding.WebName) 'utf-8' 'console output encoding'
        Assert-True ([Console]::Out.Encoding.WebName -eq 'utf-8') 'Console.Out encoder is utf-8'
        Assert-True ([HuConsoleEncoding]::RoundTrips([string][char]0x276F)) '❯ survives a round-trip'
        $bytes = [Console]::Out.Encoding.GetBytes([string][char]0x276F)
        Assert-Equal $bytes.Length 3 '❯ is three UTF-8 bytes'
        Assert-Equal $bytes[0] 0xE2 '❯ encodes as E2 9D AF'
    } finally {
        [HuConsoleEncoding]::End($snapshot)
    }
}

It 'HuConsoleEncoding.End restores the original code page' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }
    $before = [Console]::OutputEncoding.CodePage
    $snapshot = [HuConsoleEncoding]::BeginUtf8()
    [HuConsoleEncoding]::End($snapshot)
    Assert-Equal ([Console]::OutputEncoding.CodePage) $before 'code page restored'
}

It 'documented degradation: a non-UTF-8 code page turns ❯ into ?' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }
    if ([Console]::OutputEncoding.CodePage -eq 65001) { return }   # already UTF-8: nothing to degrade
    Assert-True (-not [HuConsoleEncoding]::RoundTrips([string][char]0x276F)) 'non-UTF-8 page cannot encode ❯'
    $bytes = [Console]::Out.Encoding.GetBytes([string][char]0x276F)
    Assert-Equal $bytes.Length 1 'degraded to a single byte'
    Assert-Equal $bytes[0] 0x3F "'❯' degrades to '?' (0x3F) — this is the reported bug"
}

It 'HuConsoleEncoding.End tolerates a null snapshot (no console)' {
    [HuConsoleEncoding]::End($null)     # must not throw
    Assert-True $true 'null snapshot is a no-op'
}
