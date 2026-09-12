#Requires -Version 7.0
# HuHistory.ps1 — session history for the REPL. No dependencies.

# In-memory command history with Up/Down navigation, consecutive-duplicate
# suppression, and plain-text file persistence (one line per entry; the input
# buffer is single-line, so entries never contain newlines).
class HuLineHistory {
    [System.Collections.Generic.List[string]]$Items
    [int]$Position = 0    # 0..Count-1 = entry under cursor; Count = "fresh line"

    HuLineHistory() {
        $this.Items = [System.Collections.Generic.List[string]]::new()
    }

    [void] Add([string]$line) {
        if ([string]::IsNullOrEmpty($line)) { $this.Position = $this.Items.Count; return }
        if ($this.Items.Count -gt 0 -and $this.Items[$this.Items.Count - 1] -eq $line) {
            $this.Position = $this.Items.Count
            return
        }
        $this.Items.Add($line)
        $this.Position = $this.Items.Count
    }

    # Older entry; returns $null when there is no history at all.
    # [object] return: a [string] return coerces $null to '', a bare method
    # declaration is void in PowerShell classes.
    [object] Previous() {
        if ($this.Items.Count -eq 0) { return $null }
        if ($this.Position -gt 0) { $this.Position-- }
        return $this.Items[$this.Position]
    }

    # Newer entry; '' once back at the fresh line.
    [string] Next() {
        if ($this.Items.Count -eq 0) { return '' }
        if ($this.Position -lt $this.Items.Count - 1) {
            $this.Position++
        } elseif ($this.Position -eq $this.Items.Count - 1) {
            $this.Position = $this.Items.Count
        }
        if ($this.Position -ge $this.Items.Count) { return '' }
        return $this.Items[$this.Position]
    }

    # All entries that START WITH $prefix, most recent first (case-insensitive).
    # Used by ↑-prefix-search and Ctrl+R incremental search. Empty prefix
    # returns everything (search mode starts from the full history).
    [string[]] SearchAll([string]$prefix) {
        $results = [System.Collections.Generic.List[string]]::new()
        for ($i = $this.Items.Count - 1; $i -ge 0; $i--) {
            if ($this.Items[$i].StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $results.Add($this.Items[$i])
            }
        }
        return @($results)
    }

    [void] Reset() { $this.Position = $this.Items.Count }

    # fish-style suggestion: the most recent entry that STARTS WITH $prefix
    # (case-insensitive). Returns $null when nothing matches — and when the
    # prefix is empty (an empty buffer must not permanently grey the last
    # command).
    [object] Search([string]$prefix) {
        if ([string]::IsNullOrEmpty($prefix)) { return $null }
        for ($i = $this.Items.Count - 1; $i -ge 0; $i--) {
            if ($this.Items[$i].StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $this.Items[$i]
            }
        }
        return $null
    }

    [void] Load([string]$path) {
        if (-not [System.IO.File]::Exists($path)) { return }
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            $this.Add($line)
        }
        $this.Reset()
    }

    [void] Save([string]$path) {
        if ($this.Items.Count -eq 0) { return }
        [System.IO.File]::WriteAllLines($path, [string[]]$this.Items, [System.Text.Encoding]::UTF8)
    }
}
