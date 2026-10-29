BeforeAll {
    $Source = if ($env:PROMETHEUS_CIPP_SOURCE) {
        $env:PROMETHEUS_CIPP_SOURCE
    } else {
        throw 'Set PROMETHEUS_CIPP_SOURCE to the prepared official release.'
    }
    . (Join-Path $Source 'backend/Modules/CIPPCore/Public/MCP/Get-CippMcpScopeAppSettings.ps1')
}

Describe 'MCP delegated Microsoft account selection' {
    It 'asks the connecting user to select a Microsoft account' {
        $Settings = Get-CippMcpScopeAppSettings -Hostname 'cipp.example.test' -TenantId 'partner-tenant' -IsCippNg
        $Discovery = $Settings.CRAFT_PRM_AS | ConvertFrom-Json
        $Discovery.authorization_endpoint | Should -BeExactly 'https://login.microsoftonline.com/partner-tenant/oauth2/v2.0/authorize?prompt=select_account'
        $Discovery.token_endpoint | Should -BeExactly 'https://login.microsoftonline.com/partner-tenant/oauth2/v2.0/token'
        $Discovery.registration_endpoint | Should -BeExactly '{origin}/api/PublicMcpRegister'
    }

    It 'preserves the resource, existing scopes and PKCE methods' {
        $Settings = Get-CippMcpScopeAppSettings -Hostname 'cipp.example.test' -TenantId 'partner-tenant' -IsCippNg
        $Resource = $Settings.CRAFT_PRM | ConvertFrom-Json
        $Discovery = $Settings.CRAFT_PRM_AS | ConvertFrom-Json
        $Resource.resource | Should -BeExactly '{origin}/api/ExecMcp'
        $Discovery.scopes_supported | Should -Be @('openid', 'profile', 'offline_access', 'https://cipp.example.test/user_impersonation')
        $Resource.scopes_supported | Should -Be $Discovery.scopes_supported
        $Discovery.code_challenge_methods_supported | Should -Be @('S256')
        $Settings.WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES | Should -BeExactly 'openid profile offline_access https://cipp.example.test/user_impersonation'
    }

    It 'leaves non-Craft discovery settings unchanged' {
        $Settings = Get-CippMcpScopeAppSettings -Hostname 'cipp.example.test' -TenantId 'partner-tenant'
        $Settings.Keys.Count | Should -Be 1
        $Settings.WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES | Should -BeExactly 'openid profile offline_access https://cipp.example.test/user_impersonation'
    }
}
