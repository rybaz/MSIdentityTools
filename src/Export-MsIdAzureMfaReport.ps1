﻿<#
.SYNOPSIS
    Exports a spreadsheet with a list of all the users that have signed into the Azure portal, CLI, or PowerShell.
    The report includes each user's MFA registration status.
    Required scopes: AuditLog.Read.All, UserAuthenticationMethod.Read.All

.DESCRIPTION
    - Entra ID free tenants have access to sign in logs for the last 7 days.
    - Entra ID premium tenants have access to sign in logs for the last 30 days.
    - The cmdlet will query the sign in log from the most recent day and work backwards.

    This cmdlet requires the `ImportExcel` module to be installed if you use the `-ReportOutputType ExcelWorkbook` parameter.

.EXAMPLE
    PS > Install-Module ImportExcel
    PS > Connect-MgGragh -Scopes AuditLog.Read.All, User.Read.All, UserAuthenticationMethod.Read.All
    PS > Export-MsIdAzureMfaReport -ReportOutputType ExcelWorkbook -ExcelWorkbookPath .\report.xlsx

    Queries last 30 days (7 days for Free tenants) sign in logs and outputs a report of users accessing Azure and their MFA status in Excel format.

.EXAMPLE
    PS > Export-MsIdAzureMfaReport -Days 3 -ReportOutputType ExcelWorkbook -ExcelWorkbookPath .\report.xlsx

    Queries sign in logs for the past 3 days and outputs a report of Azure users and their MFA status in Excel format.

.EXAMPLE
    PS > Export-MsIdAzureMfaReport -ReportOutputType PowerShellObjects

    Returns the results as a PowerShell object for further processing.

.EXAMPLE
    PS > Export-MsIdAzureAdminMfaReport

    Returns the results as a PowerShell object for further processing.

#>
function Export-MsIdAzureMfaReport {
    param (
        # Output file location for Excel Workbook
        [Parameter(ParameterSetName = 'Excel', Mandatory = $true, Position = 1)]
        [string]
        $ExcelWorkbookPath,

        # Output type for the report.
        [ValidateSet("ExcelWorkbook", "PowerShellObjects")]
        [Parameter(ParameterSetName = 'Excel', Mandatory = $false, Position = 2)]
        [Parameter(ParameterSetName = 'PowerShell', Mandatory = $false, Position = 1)]
        [string]
        $ReportOutputType = "ExcelWorkbook",

        # Number of days to query sign in logs. Defaults to 30 days for premium tenants and 7 days for free tenants
        [ValidateScript({
                $_ -ge 0 -and $_ -le 30
            },
            ErrorMessage = "Logs are only available for the last 7 days for free tenants and 30 days for premium tenants. Please enter a number between 0 and 30."
        )]
        [int]
        $Days,

        # Optional. Hashtable with a pre-defined list of User objects (Use Get-MsIdAzureUsers).
        [array]
        $Users,

        # Optional. Hashtable with a pre-defined list of User objects with auth methods. Used for generating spreadhsheet.
        [array]
        $UsersMfa,

        # If enabled, the user auth method will be used (slower) instead of the reporting API. Not applicable for Free tenants since they don't have access to the reporting API.
        [switch]
        $UseAuthenticationMethodEndPoint
    )

    function Main() {

        if ("ExcelWorkbook" -eq $ReportOutputType) {
            # Determine if the ImportExcel module is installed since the parameter was included
            if ($null -eq (Get-Module -Name ImportExcel -ListAvailable)) {
                throw "The ImportExcel module is not installed. This is used to export the results to an Excel worksheet. Please install the ImportExcel Module before using this parameter or run without this parameter."
            }
        }

        if ($null -eq (Get-MgContext)) {
            throw "You must connect to the Microsoft Graph before running this command."
        }

        if ($null -eq $Users -and $null -eq $UsersMfa) {
            $Users = Get-MsIdAzureUsers -Days $Days
        }

        if ($UsersMfa) { $azureUsersMfa = $UsersMfa }
        else { $azureUsersMfa = GetUserMfaInsight $Users }

        if ("PowerShellObjects" -eq $ReportOutputType) {
            return $azureUsersMfa
        }
        else {
            GenerateExcelReport $azureUsersMfa $ExcelWorkbookPath
        }
    }

    function GenerateExcelReport ($UsersMfa, $Path) {

        $maxRows = $UsersMfa.Count + 1

        $UsersMfa = $UsersMfa | Sort-Object -Property IsMfaRegistered, UserDisplayName

        # Delete the existing output file if it already exists
        $OutputFileExists = Test-Path $Path
        if ($OutputFileExists -eq $true) {
            Get-ChildItem $Path | Remove-Item -Force
        }

        $headerBgColour = [System.Drawing.ColorTranslator]::FromHtml("#0077b6")
        $darkGrayColour = [System.Drawing.ColorTranslator]::FromHtml("#A9A9A9")
        $styles = @(
            New-ExcelStyle -Range "A1:J$maxRows" -Height 20 -FontSize 14
            New-ExcelStyle -Range "A1:J1" -FontColor White -BackgroundColor $headerBgColour -Bold -HorizontalAlignment Center
            New-ExcelStyle -Range "A2:A$maxRows" -FontColor Blue -Underline
            New-ExcelStyle -Range "D2:D$maxRows" -FontColor Blue -Underline
            New-ExcelStyle -Range "E2:G$maxRows" -FontColor Blue
            New-ExcelStyle -Range "C2:G$maxRows" -HorizontalAlignment Center
            New-ExcelStyle -Range "I2:I$maxRows" -FontColor $darkGrayColour -HorizontalAlignment Fill
        )

        $authMethodBlade = 'https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/UserAuthMethods/userId/%id%/hidePreviewBanner~/true'
        $userBlade = 'https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/%id%/hidePreviewBanner~/true'

        $report = $UsersMfa | Select-Object `
        @{name = 'Name'; expression = { GetLink $userBlade $_.UserId $_.UserDisplayName } }, UserPrincipalName, `
        @{name = ' '; expression = {
                if ($_.IsMfaRegistered) { $mfa = '✅' } else { $mfa = '❌' }
                $mfa
            }
        }, `
        @{name = 'MFA Status'; expression = {
                if ($_.IsMfaRegistered) { $mfa = 'MFA Registered' } else { $mfa = 'No MFA Registered' }
                GetLink $authMethodBlade $_.UserId $mfa
            }
        }, `
        @{name = 'Az Portal'; expression = { GetTickSymbol $_.AzureAppName "Azure Portal" } }, `
        @{name = 'Az CLI'; expression = { GetTickSymbol $_.AzureAppName "Azure CLI" } }, `
        @{name = 'Az PowerShell'; expression = { GetTickSymbol $_.AzureAppName "Azure PowerShell" } }, `
        @{name = 'Authentication Methods'; expression = { $_.AuthenticationMethods -join ', ' } }, UserId, `
        @{name = 'Notes'; expression = { if ([string]::IsNullOrEmpty($_.Notes)) { "' " } else { $_.Notes } } } `


        $excel = $report | Export-Excel -Path $Path -WorksheetName "MFA Report" `
            -FreezeTopRow `
            -Activate `
            -Style $styles `
            -HideSheet "None" `
            -PassThru `
            -IncludePivotChart -PivotTableName "MFA Readiness" -PivotRows "MFA Status" -PivotData @{'MFA Status' = 'count' } -PivotChartType PieExploded3D -ShowPercent

        $sheet = $excel.Workbook.Worksheets["MFA Report"]
        $sheet.Column(1).Width = 35 #DisplayName
        $sheet.Column(2).Width = 35 #UPN
        $sheet.Column(3).Width = 6 #MFA Icon
        $sheet.Column(4).Width = 22 #MFA Registered
        $sheet.Column(5).Width = 17 #Azure Portal
        $sheet.Column(6).Width = 17 #Azure CLI
        $sheet.Column(7).Width = 17 #Azure PowerShell
        $sheet.Column(8).Width = 40 #AuthenticationMethods
        $sheet.Column(9).Width = 15 #UserId
        $sheet.Column(10).Width = 30 #Notes

        Add-ConditionalFormatting -Worksheet $sheet -Range "C2:C$maxRows" -ConditionValue '=$C2="✅"' -RuleType Expression -ForegroundColor Green
        Add-ConditionalFormatting -Worksheet $sheet -Range "C2:C$maxRows" -ConditionValue '=$C2="❌"' -RuleType Expression -ForegroundColor Red

        Export-Excel -ExcelPackage $excel -WorksheetName "MFA Report" -Activate

        Write-Verbose ("Excel workbook {0}" -f $ExcelWorkbookPath)

    }

    function GetTickSymbol($source, $matchString) {
        if ($source -match $matchString) { return "🔵" }
        return ""
    }

    function GetLink($uriFormat, $id, $name) {
        $uri = $uriFormat -replace '%id%', $id
        $hyperlink = '=Hyperlink("%uri%", "%name%")'
        $hyperlink = $hyperlink -replace '%uri%', $uri
        $hyperlink = $hyperlink -replace '%name%', $name
        Write-Verbose $hyperlink
        return ( $hyperlink)
    }

    # Get the authentication method state for each user
    function GetUserMfaInsight($users) {

        if ($UseAuthenticationMethodEndPoint) { $isPremiumTenant = $false } # Force into free tenant mode
        else { $isPremiumTenant = GetIsPremiumTenant $users }

        #$users = $users | Select-Object -First 10 # For testing

        $totalCount = $users.Count
        $currentCount = 0
        foreach ($user in $users) {
            Write-Verbose $user.UserId
            Write-Verbose $user.UserPrincipalName

            $currentCount++
            AddMfaProperties $user
            UpdateProgress $currentCount $totalCount $user

            $graphUri = (GetGraphBaseUri) + "/v1.0/users/$($user.UserId)/authentication/methods"
            if ($isPremiumTenant) {
                $graphUri = (GetGraphBaseUri) + "/v1.0/reports/authenticationMethods/userRegistrationDetails/$($user.UserId)"
            }
            $resultJson = Invoke-MgGraphRequest -Uri $graphUri -Method GET -SkipHttpErrorCheck
            $err = Get-ObjectPropertyValue $resultJson -Property "error"

            if ($err) {
                $note = "Could not retrieve authentication methods for user."

                if ($null -ne $err) {
                    $note = $err.message
                }
                $user.Note = $note
                continue
            }

            if ($isPremiumTenant) {
                $methodsRegistered = Get-ObjectPropertyValue $resultJson -Property 'methodsRegistered'
                $userAuthMethod = @()
                foreach ($method in $methodsRegistered) {
                    $methodInfo = $authMethods | Where-Object { $_.ReportType -eq $method }
                    if ($null -eq $methodInfo) { $userAuthMethod += $method }
                    else { $userAuthMethod += $methodInfo.DisplayName }
                }
                $user.AuthenticationMethods = $userAuthMethod -join ', '
                $user.IsMfaRegistered = Get-ObjectPropertyValue $resultJson -Property 'isMfaRegistered'
            }
            else {
                $graphMethods = Get-ObjectPropertyValue $resultJson -Property "value"
                $userAuthMethods = @()
                $isMfaRegistered = $false
                $types = $graphMethods | Select-Object '@odata.type' -Unique
                foreach ($method in $types) {
                    $type = $method.'@odata.type'
                    Write-Verbose "Type: $type"
                    $userAuthMethod = GetAuthMethodInfo $type
                    if ($userAuthMethod.IsMfa) {
                        $isMfaRegistered = $true
                        $userAuthMethods += $userAuthMethod.DisplayName
                    }
                }
                $user.AuthenticationMethods = $userAuthMethods
                $user.IsMfaRegistered = $isMfaRegistered
            }
        }

        return $users
    }

    # Check if the tenant has permissions to call the user registration API.
    function GetIsPremiumTenant($users) {
        $isPremiumTenant = $true
        if ($users -and $users.Count -gt 0) {
            $user = $users[0]
            $graphUri = (GetGraphBaseUri) + "/v1.0/reports/authenticationMethods/userRegistrationDetails/$($user.UserId)"
            $resultJson = Invoke-MgGraphRequest -Uri $graphUri -Method GET -SkipHttpErrorCheck
            $err = Get-ObjectPropertyValue $resultJson -Property "error"

            if ($err) {
                $isPremiumTenant = $err.code -ne "Authentication_RequestFromNonPremiumTenantOrB2CTenant"
            }
        }
        return $isPremiumTenant
    }
    function AddMfaProperties($user) {
        $user | Add-Member -MemberType NoteProperty -Name "Note" -Value $null -ErrorAction SilentlyContinue
        $user | Add-Member -MemberType NoteProperty -Name "AuthenticationMethods" -Value $null -ErrorAction SilentlyContinue
        $user | Add-Member -MemberType NoteProperty -Name "IsMfaRegistered" -Value $null -ErrorAction SilentlyContinue
    }

    function UpdateProgress($currentCount, $totalCount, $user) {
        $userStatusDisplay = $user.UserId

        if ([bool]$user.PSObject.Properties["UserPrincipalName"]) {
            $userStatusDisplay = $user.UserPrincipalName
        }

        $percent = [math]::Round(($currentCount / $totalCount) * 100)

        Write-Progress -Activity "Getting authentication method" -Status "[$currentCount of $totalCount] Checking $userStatusDisplay. $percent% complete" -PercentComplete $percent

    }
    function GetGraphBaseUri() {
        return $((Get-MgEnvironment -Name (Get-MgContext).Environment).GraphEndpoint)
    }

    function WriteExportProgress(
        # The current step of the overal generation
        [ValidateSet("ServicePrincipal", "AppPerm", "DownloadDelegatePerm", "ProcessDelegatePerm", "GenerateExcel", "Complete")]
        $MainStep,
        $Status = "Processing...",
        # The percentage of completion within the child step
        $ChildPercent,
        [switch]$ForceRefresh) {
        $percent = 0
        switch ($MainStep) {
            "ServicePrincipal" {
                $percent = GetNextPercent $ChildPercent 2 10
                $activity = "Downloading service principals"
            }
            "AppPerm" {
                $percent = GetNextPercent $ChildPercent 10 50
                $activity = "Downloading application permissions"
            }
            "DownloadDelegatePerm" {
                $percent = GetNextPercent $ChildPercent 50 75
                $activity = "Downloading delegate permissions"
            }
            "ProcessDelegatePerm" {
                $percent = GetNextPercent $ChildPercent 75 90
                $activity = "Processing delegate permissions"
            }
            "GenerateExcel" {
                $percent = GetNextPercent $ChildPercent 90 99
                $activity = "Processing risk information"
            }
            "Complete" {
                $percent = 100
                $activity = "Complete"
            }
        }

        if ($ForceRefresh.IsPresent) {
            Start-Sleep -Milliseconds 250
        }
        Write-Progress -Id 0 -Activity $activity -PercentComplete $percent -Status $Status
    }

    # #, Mobile phone, Office phone, Alternate mobile phone, Security question, , , Hardware OATH token, FIDO2 security key, , Microsoft Passwordless phone sign-in, ,  , Passkey (Microsoft Authenticator), Passkey (Windows Hello)

    function GetAuthMethodInfo($type) {
        $methodInfo = $authMethods | Where-Object { $_.Type -eq $type }
        if ($null -eq $methodInfo) {
            # Default to the type and assume it is MFA
            $methodInfo = @{
                Type        = $type
                DisplayName = ($type -replace '#microsoft.graph.', '') -replace 'AuthenticationMethod', ''
                IsMfa       = $true
            }
        }
        return $methodInfo
    }

    $authMethods = @(
        @{
            ReportType  = 'passKeyDeviceBoundAuthenticator'
            Type        = $null
            DisplayName = 'Passkey (Microsoft Authenticator)'
            IsMfa       = $true
        },
        @{
            ReportType  = 'passKeyDeviceBound'
            Type        = '#microsoft.graph.fido2AuthenticationMethod'
            DisplayName = "Passkey (other device-bound)"
            IsMfa       = $true
        },
        @{
            ReportType  = 'email'
            Type        = '#microsoft.graph.emailAuthenticationMethod'
            DisplayName = 'Email'
            IsMfa       = $false
        },
        @{
            ReportType  = 'microsoftAuthenticatorPush'
            Type        = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'
            DisplayName = 'Microsoft Authenticator'
            IsMfa       = $true
        },
        @{
            ReportType  = 'mobilePhone'
            Type        = '#microsoft.graph.phoneAuthenticationMethod'
            DisplayName = 'Phone'
            IsMfa       = $true
        },
        @{
            ReportType  = 'softwareOneTimePasscode'
            Type        = '#microsoft.graph.softwareOathAuthenticationMethod'
            DisplayName = 'Authenticator app (TOTP)'
            IsMfa       = $true
        },
        @{
            ReportType  = $null
            Type        = '#microsoft.graph.temporaryAccessPassAuthenticationMethod'
            DisplayName = 'Temporary Access Pass'
            IsMfa       = $false
        },
        @{
            ReportType  = 'windowsHelloForBusiness'
            Type        = '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod'
            DisplayName = 'Windows Hello for Business'
            IsMfa       = $true
        },
        @{
            ReportType  = $null
            Type        = '#microsoft.graph.passwordAuthenticationMethod'
            DisplayName = 'Password'
            IsMfa       = $false
        },
        @{
            ReportType  = $null
            Type        = '#microsoft.graph.platformCredentialAuthenticationMethod'
            DisplayName = 'Platform Credential for MacOS'
            IsMfa       = $true
        },
        @{
            ReportType  = 'microsoftAuthenticatorPasswordless'
            Type        = '#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod'
            DisplayName = 'Microsoft Authenticator'
            IsMfa       = $true
        }
    )

    # Call main function
    Main
}
