@{
    IncludeDefaultRules = $true
    Severity = @('Error', 'Warning')
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSAvoidUsingCmdletAliases = @{ Enable = $true }
        PSAvoidUsingInvokeExpression = @{ Enable = $true }
        PSAvoidGlobalVars = @{ Enable = $true }
    }
}
