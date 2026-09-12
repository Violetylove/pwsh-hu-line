# HuCommandHighlighter tests — command-name colouring with a FAKE resolver, so the
# expectations are about the highlighter and not about this machine's commands.

function New-CmdHighlighter([hashtable]$Kinds) {
    $resolver = { param($name) if ($Kinds.ContainsKey($name)) { return $Kinds[$name] } else { return 'unknown' } }.GetNewClosure()
    return [HuCommandHighlighter]::new($resolver)
}

# Renders the regions as "start..end:colour" so expectations read as spans.
function Get-CmdSpan($Regions) {
    $out = @()
    foreach ($r in $Regions) { $out += ('{0}..{1}:{2}' -f $r.Start, $r.End, $r.Style.Foreground) }
    return ($out -join ',')
}

It 'command: everything that resolves gets ONE colour' {
    $h = New-CmdHighlighter @{ 'Get-ChildItem' = 'command'; 'v' = 'alias'; 'nvim' = 'application' }
    Assert-Equal (Get-CmdSpan $h.GetRegions('Get-ChildItem')) '0..13:green' 'cmdlet'
    Assert-Equal (Get-CmdSpan $h.GetRegions('v')) '0..1:green' 'alias — same colour'
    Assert-Equal (Get-CmdSpan $h.GetRegions('nvim')) '0..4:green' 'external program — same colour'
    Assert-Equal (Get-CmdSpan $h.GetRegions('zzz')) '0..3:red' 'unknown stays distinct'
}

It 'command: colours the command name only, not its arguments' {
    $h = New-CmdHighlighter @{ 'Get-ChildItem' = 'command'; 'C:\Windows' = 'command' }
    Assert-Equal (Get-CmdSpan $h.GetRegions('Get-ChildItem C:\Windows')) '0..13:green' 'just the name'
}

It 'command: every command in a sequence or pipeline' {
    $h = New-CmdHighlighter @{ 'Get-X' = 'command'; 'bar' = 'command' }
    Assert-Equal (Get-CmdSpan $h.GetRegions('Get-X | foo; bar')) '0..5:green,8..11:red,13..16:green' 'three names'
}

It 'command: a quoted command name keeps its quotes in the span' {
    # `& 'name'` is the shape that makes a quoted string a command name; a bare
    # leading quote is a parse error and the parser hands the trailing token over
    # as the command instead (scratch/quote-probe.ps1).
    $h = New-CmdHighlighter @{ 'Get-ChildItem' = 'command' }
    Assert-Equal (Get-CmdSpan $h.GetRegions("& 'Get-ChildItem' x")) '2..17:green' 'extent includes quotes'
}

It 'command: variable and wildcard names are left untouched' {
    $h = New-CmdHighlighter @{}
    Assert-Equal (Get-CmdSpan $h.GetRegions('$cmd foo*')) '' 'nothing to classify'
    Assert-Equal (Get-CmdSpan $h.GetRegions('')) '' 'empty buffer'
}

It 'command: a disabled class emits no region' {
    $h = New-CmdHighlighter @{}
    $h.UnknownStyle = $null
    Assert-Equal (Get-CmdSpan $h.GetRegions('zzz')) '' 'unknown colouring off'
}

It 'command: colours use targeted SGR (turn on 32/31, turn off 39)' {
    $h = New-CmdHighlighter @{}
    Assert-Equal $h.CommandStyle.ToSgrOn() '32' 'green on'
    Assert-Equal $h.CommandStyle.ToSgrOff() '39' 'foreground off only'
    Assert-Equal $h.UnknownStyle.ToSgrOn() '31' 'red on'
}

It 'command: classifications are cached per instance' {
    $calls = @{ N = 0 }
    $resolver = { param($name) $calls.N++; return 'command' }.GetNewClosure()
    $h = [HuCommandHighlighter]::new($resolver)
    $null = $h.GetRegions('Get-ChildItem')
    $null = $h.GetRegions('Get-ChildItem')
    Assert-Equal $calls.N 1 'resolved once'
}

It 'command: a shared cache is reused across instances (one per session)' {
    $calls = @{ N = 0 }
    $resolver = { param($name) $calls.N++; return 'command' }.GetNewClosure()
    $cache = @{}
    $a = [HuCommandHighlighter]::new($resolver, $cache)
    $b = [HuCommandHighlighter]::new($resolver, $cache)
    $null = $a.GetRegions('Get-ChildItem')
    $null = $b.GetRegions('Get-ChildItem')
    Assert-Equal $calls.N 1 'second instance hits the shared cache'
}
