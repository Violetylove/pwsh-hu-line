@{
    RootModule           = 'pwsh-hu-line.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7f2d5a4e-9c31-4b8a-a6f0-2d1e8c9b4a77'
    Author               = 'Winter'
    CompanyName          = ''
    Copyright            = '(c) Winter. MIT License.'
    Description          = 'A PowerShell line editor: zsh-style live path underlining, command-name colouring, fish-style history suggestions, Tab completion menu. An in-process module that takes over the interactive loop at pwsh startup.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Read-HuLine', 'Enter-HuLineRepl', 'Get-HuRegions')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('line-editor', 'terminal', 'highlighting', 'readline')
            ProjectUri = ''
        }
    }
}
