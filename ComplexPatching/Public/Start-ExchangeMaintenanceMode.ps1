function Start-ExchangeMaintenanceMode {
    param
    (
        [parameter(Mandatory = $true)]
        [string]$ComputerName,
        # Provides the computer name to check services on

        [parameter(Mandatory = $true)]
        [string]$Grouping,
        # Provides the grouping for the computer


        [parameter(Mandatory = $true)]
        [string]$DryRun,
        # skips patching check so that we can perform a dry run of the drain an resume

        [parameter(Mandatory = $true)]
        [int32]$RBInstance,
        # RBInstance which represents the Runbook Process ID for this runbook workflow

        [parameter(Mandatory = $true)]
        [string]$SQLServer,
        # Database server for staging information during the patching process

        [parameter(Mandatory = $true)]
        [string]$OrchStagingDB,
        # Database for staging information during the patching process

        [parameter(Mandatory = $true)]
        [string]$LogLocation
        # UNC path to store log files in
    )

    #region import modules
    Import-Module -Name ComplexPatching
    #endregion import modules

    #-----------------------------------------------------------------------

    ## Initialize result and trace variables
    # $ResultStatus provides basic success/failed indicator
    # $ErrorMessage captures any error text generated by script
    # $Trace is used to record a running log of actions
    [bool]$DryRun = ConvertTo-Boolean $DryRun
    $ErrorMessage = ""
    $global:CurrentAction = ""
    $ScriptName = $((Split-Path $PSCommandPath -Leaf) -Replace '.ps1', $null)

    #region set our defaults for the our functions
    #region Write-CMLogEntry defaults
    $Bias = Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Bias", $Bias)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Folder", $LogLocation)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Component", "[$ComputerName]::[$ScriptName]")
    #endregion Write-CMLogEntry defaults

    #region Update-DBServerStatus defaults
    $PSDefaultParameterValues.Add("Update-DBServerStatus:ComputerName", $ComputerName)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:RBInstance", $RBInstance)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:Database", $OrchStagingDB)
    #endregion Update-DBServerStatus defaults

    #region Start-CompPatchQuery defaults
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:Database", $OrchStagingDB)
    #endregion Start-CompPatchQuery defaults
    #endregion set our defaults for our functions

    Write-CMLogEntry "Runbook activity script started - [Running On = $env:ComputerName]"
    Update-DBServerStatus -Status "Started $ScriptName"
    Update-DBServerStatus -Stage 'Start' -Component $ScriptName -DryRun $DryRun

    try {
        $ErrorActionPreference = "Stop"

        #region create credential objects
        Write-CMLogEntry "Creating necessary credential objects"
        $ExchangeCreds = Get-StoredCredential -Purpose DevExchange -SQLServer $SQLServer -Database $OrchStagingDB
        $RemotingCreds = Get-StoredCredential -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
        #endregion create credential objects

        $FQDN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB

        #region validate that other servers in grouping haven't failed
        Update-DBServerStatus -LastStatus "Validating Exchange partners"
        $PartnerServer_StatusQuery = [string]::Format("SELECT * FROM [dbo].[ServerStatus] WHERE (Status LIKE '%Fail%' OR LastStatus LIKE '%Fail%') AND PatchStrategy = 'EXCH' AND Grouping = '{0}'", $Grouping)
        $PartnerServer_Status = Start-CompPatchQuery -Query $PartnerServer_StatusQuery
        if ($null -ne $PartnerServer_Status) {
            foreach ($Server in $PartnerServer_Status) {
                Write-CMLogEntry "Failure identified - [ComputerName=$($Server.ServerName)] [Status=$($Server.Status)] [LastStatus=$($Server.LastStatus)]" -Severity 3
            }
            Write-CMLogEntry "Identified partner servers in a failure state. Patching will stop." -Severity 3
            throw "Identified partner servers in a failure state. Patching will stop."
        }
        #endregion validate that other servers in grouping haven't failed

        #region initiate CIMSession, looping until one is made, or it has been 10 minutes
        Update-DBServerStatus -LastStatus 'Creating CIMSession'
        Write-CMLogEntry 'Creating CIMSession'    
        $newLoopActionSplat = @{
            LoopTimeoutType = 'Minutes'
            ExitCondition   = { $script:CIMSession }
            IfTimeoutScript = {
                Write-CMLogEntry 'Failed to create CIMSession'
                throw 'Failed to create CIMsession'
            }
            ScriptBlock     = {
                $script:CIMSession = New-MrCimSession -Credential $script:RemotingCreds -ComputerName $script:FQDN
            }
            LoopDelay       = 10
            IfSucceedScript = { 
                Update-DBServerStatus -LastStatus "CIMSession Created"
                Write-CMLogEntry 'CIMSession created succesfully' 
            }
            LoopTimeout     = 10
        }
        New-LoopAction @newLoopActionSplat
        #endregion initiate CIMSession, looping until one is made, or it has been 10 minutes
    
        #region import exchange session
        $Attempts = 0
        do {
            $FindMBXQuery = [string]::Format(@"
SELECT [ServerName] FROM [dbo].[ServerStatus] WHERE [Grouping] = (SELECT [Grouping] FROM [dbo].[ServerStatus] WHERE [ServerName] = '{0}') AND [Role] = 'MBX'
"@, $ComputerName)
            $startCompPatchQuerySplat = @{
                Query     = $FindMBXQuery
                Folder    = $LogLocation
                Component = "[$ComputerName]::[$ScriptName]"
                Filename  = [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName)
                Log       = $true
            }
            $ExchangesBoxes = @(Start-CompPatchQuery @startCompPatchQuerySplat | Select-Object -ExpandProperty ServerName | Where-Object { $_ -ne $ComputerName })
            $MaxAttempts = $ExchangesBoxes | Measure-Object | Select-Object -ExpandProperty Count
            $ExchangeUtil = $ExchangesBoxes[$Attempts]
            $ExchangeUtilFQDN = Get-FQDNFromDB -ComputerName $ExchangeUtil -SQLServer $SQLServer -Database $OrchStagingDB
            $ConnectionURI = [string]::Format("http://{0}/PowerShell/", $ExchangeUtilFQDN)
            try {
                Write-CMLogEntry "Attempt to create PSSession to $ConnectionURI"
                $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri $ConnectionURI -Credential $ExchangeCreds -Authentication Kerberos
                Write-CMLogEntry "Importing PSSession from $ExchangeUtilFQDN to allow for implicit remoting"    
                Import-PSSession -Session $Session -ErrorAction Stop -AllowClobber
                Write-CMLogEntry "Created and imported PSSession from $ExchangeUtilFQDN"
            }
            catch {
                Write-CMLogEntry "Failed to create or import PSSEssion to $ExchangeUtilFQDN - will try against another server" -Severity 2
                $Attempts++
            }
        }
        until($Session -or $Attempts -eq $MaxAttempts)
        #endregion import exchange session

        #region functions
        function Set-ExchMaintenanceMode {
            param (
                [parameter(Mandatory = $true)]
                [string]$ComputerName,
                [parameter(Mandatory = $true, ParameterSetName = 'On')]
                [switch]$On,
                [parameter(Mandatory = $true, ParameterSetName = 'On')]
                [string]$TargetServer,
                [parameter(Mandatory = $true, ParameterSetName = 'Off')]
                [switch]$Off,
                [parameter(Mandatory = $true)]
                [pscredential]$RemotingCredential
            )

            $PSDefaultParameterValues = $Global:PSDefaultParameterValues

            switch ($PSCmdlet.ParameterSetName) {
                On {
                    Write-CMLogEntry "Validating that $ComputerName is a valid exchange server."
                    $ExchangeServer = Get-ExchangeServer -Identity $ComputerName
                    $PatchingServerFDQN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
                    if ($ExchangeServer | Select-Object -ExpandProperty IsHubTransportServer) {
                        Write-CMLogEntry "Validated that $ComputerName is a valid Exchange server"
                        #region validate that targetserver is a valid exchange mailbox server that is not in maintenance mode
                        Write-CMLogEntry "Validating that $TargetServer is a viable exchange server to transfer messages to."
                        try {
                            $TargetFQDN = Get-FQDNFromDB -ComputerName $TargetServer -SQLServer $SQLServer -Database $OrchStagingDB
                            Write-CMLogEntry "Validated Target Server FQDN to be $TargetFQDN"
                        }
                        catch {
                            Write-CMLogEntry -Value "Failed to resolved FQDN based on TargetServer value of $TargetServer" -Severity 3
                            throw "Failed to resolved FQDN based on TargetServer value of $TargetServer"
                        }
                        if (Test-Connection -ComputerName $TargetFQDN -Count 2 -Quiet) {
                            $IsHubTransportServer = [bool](Get-ExchangeServer -Identity $TargetServer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IsHubTransportServer)
                            if ($IsHubTransportServer) {
                                $TargetServerStatus = Get-ExchMaintenanceMode -ComputerName $TargetServer -RemotingCredential $RemotingCredential
                                if ($TargetServerStatus -eq 'MaintenanceModeOff') {
                                    Write-CMLogEntry "Identified valid target server for the Redirect-Message command - $TargetServer"
                                    $ValidTargetServer = $TargetFQDN
                                }
                                else {
                                    Write-CMLogEntry -Value "Provided targetserver $TargetServer is currently in some form of maintenance mode" -Severity 3
                                    throw "Provided targetserver $TargetServer is currently in some form of maintenance mode"
                                }
                            }
                            else {
                                Write-CMLogEntry -Value "Failed to confirm that the targetserver $TargetServer is a hub transport server" -Severity 3
                                throw "Failed to confirm that the targetserver $TargetServer is a hub transport server"
                            }
                        }
                        else {
                            Write-CMLogEntry -Value "Failed to confirm that the targetserver $TargetServer is powered on" -Severity 3
                            throw "Failed to confirm that the targetserver $TargetServer is powered on"
                        }
                        #endregion validate that targetserver is a valid exchange mailbox server that is not in maintenance mode

                        Write-CMLogEntry "Instructing HubTransport component on $ComputerName to begin draining"
                        $setServerComponentStateSplat = @{
                            State     = 'Draining'
                            Component = 'HubTransport'
                            Requester = 'Maintenance'
                            Identity  = $ComputerName
                        }
                        Set-ServerComponentState @setServerComponentStateSplat
                        Write-CMLogEntry "Restarting MSExchangeTransport service on $ComputerName"
                        Invoke-Command -ComputerName $PatchingServerFDQN -ScriptBlock { Restart-Service -Name MSExchangeTransport } -Credential $RemotingCredential
                        Write-CMLogEntry "Redirecting messages from $ComputerName to $ValidTargetServer"
                        Redirect-Message -Server $ComputerName -Target $ValidTargetServer -Confirm:$False

                        $MailboxServer = Get-MailboxServer -Identity $ComputerName
                        if ($null -ne $MailboxServer.DatabaseAvailabilityGroup) {
                            Write-CMLogEntry "$ComputerName is part of a database availability group - will suspend"
                            Start-ScheduledTask -TaskName 'Suspend-ClusterNode' -CimSession $script:CIMSession -ErrorAction Stop
                            Set-MailboxServer -Identity $ComputerName -DatabaseCopyActivationDisabledAndMoveNow $True
                            Set-MailboxServer -Identity $ComputerName -DatabaseCopyAutoActivationPolicy Blocked
                        }

                        #region ensure our Message Queue is empty
                        $newLoopActionSplat = @{
                            LoopTimeoutType = 'Minutes'
                            ScriptBlock     = {
                                $MessageCount = Get-Queue -Server $script:ComputerName -Exclude ShadowRedundancy | Where-Object { $_.Identity -notmatch 'Poison' } | Measure-Object -Property MessageCount -Sum | Select-Object -ExpandProperty Sum
                                Write-CMLogEntry "Waiting for message queue to be empty on $script:ComputerName - Currently $MessageCount messages in the queue"
                            }
                            ExitCondition   = { $MessageCount -eq 0 }
                            IfTimeoutScript = {
                                Write-CMLogEntry -Value "Failed to validate that $script:ComputerName has an empty message queue after 30 minutes." -Severity 3
                                throw "Failed to validate that $script:ComputerName has an empty message queue after 30 minutes."
                            }
                            LoopDelayType   = 'Seconds'
                            LoopDelay       = 10
                            IfSucceedScript = { Write-CMLogEntry "Validated that $script:ComputerName has an empty message queue" }
                            LoopTimeout     = 30
                        }
                        New-LoopAction @newLoopActionSplat
                        #endregion ensure our Message Queue is empty
                    }
                    Write-CMLogEntry "Setting [ServerWideOffline=Inactive] for $ComputerName"
                    Set-ServerComponentState -Identity $ComputerName -Component ServerWideOffline -State Inactive -Requester Maintenance
                }
                Off {
                    Write-CMLogEntry "Setting [ServerWideOffline=Active] for $ComputerName"
                    Set-ServerComponentState -Identity $ComputerName -Component ServerWideOffline -State Active -Requester Maintenance

                    $ExchangeServer = Get-ExchangeServer -Identity $ComputerName
                    $PatchingServerFDQN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
                    if ($ExchangeServer | Select-Object -ExpandProperty IsHubTransportServer) {
                        $MailboxServer = Get-MailboxServer -Identity $ComputerName
                        if ($null -ne $MailboxServer.DatabaseAvailabilityGroup) {
                            Write-CMLogEntry "$ComputerName is part of a database availability group - will resume"
                            Start-ScheduledTask -TaskName 'Resume-ClusterNode' -CimSession $script:CIMSession -ErrorAction Stop
                            Set-MailboxServer -Identity $ComputerName -DatabaseCopyActivationDisabledAndMoveNow $False
                            Set-MailboxServer -Identity $ComputerName -DatabaseCopyAutoActivationPolicy Unrestricted
                        }
                        Write-CMLogEntry "Setting HubTransport component on $ComputerName to Active"
                        Set-ServerComponentState -Identity $ComputerName -Component HubTransport -State Active -Requester Maintenance
                        Write-CMLogEntry "Restarting MSExchangeTransport service on $ComputerName"
                        Invoke-Command -ComputerName $PatchingServerFDQN -ScriptBlock { Restart-Service -Name MSExchangeTransport } -Credential $RemotingCredential
                        if ($ExchangeServer.IsFrontendTransportServer) {
                            Write-CMLogEntry "Restarting MSExchangeFrontEndTransport service on $ComputerName"
                            Invoke-Command -ComputerName $PatchingServerFDQN { Restart-Service MSExchangeFrontEndTransport } -Credential $RemotingCredential
                        }
                    }
                }
            }
        }

        function Get-ExchMaintenanceMode {
            param
            (
                [parameter(Mandatory = $true)]
                [string]$ComputerName,
                [parameter(Mandatory = $true)]
                [pscredential]$RemotingCredential,
                [parameter(Mandatory = $false)]
                [switch]$ReturnState
            )

            $ClusterNodeLookup = @{
                0 = 'NotInitiated'
                1 = 'InProgres'
                2 = 'Completed'
                3 = 'Failed'
            }
            $ExchangeServer = Get-ExchangeServer -Identity $ComputerName
            $MailboxServer = Get-MailboxServer -Identity $ComputerName
            $ServerFDQN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
            $HubTransport = Get-ServerComponentState -Identity $ComputerName -Component HubTransport | Select-Object -ExpandProperty State
            $ServerWideOffline = Get-ServerComponentState -Identity $ComputerName -Component ServerWideOffline | Select-Object -ExpandProperty State
            $getWmiObjectSplat = @{
                Filter       = "Name='$ComputerName'"
                ComputerName = $ServerFDQN
                Property     = 'State'
                Namespace    = 'root\mscluster'
                Credential   = $RemotingCredential
                Class        = 'MSCluster_Node'
            }
            try {
                [int32]$ClusterNodeStateRAW = Get-WmiObject @getWmiObjectSplat -ErrorAction Stop | Select-Object -ExpandProperty State
                $ClusterNodeState = $ClusterNodeLookup[$ClusterNodeStateRAW]
            }
            catch {
                $ClusterNodeState = 'Failure to lookup'
            }

            #region generate an arraylist of properties that will need compared to determine if a server is in maintenance mode
            $PropertiesToCompare = [System.Collections.ArrayList]::new()
            $PropertiesToCompare.Add('ServerWideOffline') | Out-Null
            if ($ExchangeServer.IsHubTransportServer) {
                $PropertiesToCompare.Add('HubTransport') | Out-Null
            }
            if ($null -ne $MailboxServer.DatabaseAvailabilityGroup) {
                $PropertiesToCompare.Add('DatabaseCopyAutoActivationPolicy') | Out-Null
                $PropertiesToCompare.Add('DatabaseCopyActivationDisabledAndMoveNow') | Out-Null
                $PropertiesToCompare.Add('ClusterNodeDrainStatus') | Out-Null
            }
            #endregion generate an arraylist of properties that will need compared to determine if a server is in maintenance mode

            #region define what is 'on' and 'off' for maintenance mode. Note that our dynamic propertiestocompare allows us to have this be 'all' things we are concerned about
            $On = [PSCustomObject]@{
                HubTransport                             = 'Inactive'
                ServerWideOffline                        = 'Inactive'
                DatabaseCopyAutoActivationPolicy         = 'Blocked'
                DatabaseCopyActivationDisabledAndMoveNow = $true
                ClusterNodeDrainStatus                   = 'Completed'
            }
            $Off = [PSCustomObject]@{
                HubTransport                             = 'Active'
                ServerWideOffline                        = 'Active'
                DatabaseCopyAutoActivationPolicy         = 'Unrestricted'
                DatabaseCopyActivationDisabledAndMoveNow = $False
                ClusterNodeDrainStatus                   = 'NotInitiated'
            }
            #endregion define what is 'on' and 'off' for maintenance mode. Note that our dynamic propertiestocompare allows us to have this be 'all' things we are concerned about

            $CurrentState = [PSCustomObject]@{
                ComputerName                             = $ComputerName
                HubTransport                             = $HubTransport
                ServerWideOffline                        = $ServerWideOffline
                DatabaseCopyAutoActivationPolicy         = $($MailboxServer | Select-Object -ExpandProperty DatabaseCopyAutoActivationPolicy)
                DatabaseCopyActivationDisabledAndMoveNow = $($MailboxServer | Select-Object -ExpandProperty DatabaseCopyActivationDisabledAndMoveNow)
                ClusterNodeDrainStatus                   = $ClusterNodeState
            }

            if (-not $Returnstate) {
                if ($null -eq (Compare-Object -ReferenceObject $On -DifferenceObject $CurrentState -Property $PropertiesToCompare)) {
                    return 'MaintenanceModeOn'
                }
                elseif ($null -eq (Compare-Object -ReferenceObject $Off -DifferenceObject $CurrentState -Property $PropertiesToCompare)) {
                    return 'MaintenanceModeOff'
                }
                else {
                    return 'Partial'
                }
            }
            else {
                return $CurrentState
            }
        }
        #endregion functions

        #region make sure we are ok to proceed!
        Update-DBServerStatus -LastStatus "Validating no servers in maintenance mode at start"
        $ExchEnvStatus = foreach ($MailboxServer in (Get-MailboxServer | Select-Object -ExpandProperty name)) {
            $Status = Get-ExchMaintenanceMode -ComputerName $MailboxServer -RemotingCredential $RemotingCreds
            [pscustomobject]@{
                ServerName = $MailboxServer
                Status     = $Status
            }
        }

        if ($null -ne ($ExchEnvStatus | Select-Object -ExpandProperty Status -Unique | Where-Object { $_ -ne 'MaintenanceModeOff' })) {
            $NotOff = $ExchEnvStatus | Where-Object { $_.Status -ne 'MaintenanceModeOff' }
            foreach ($Server in $NotOff) {
                $ServerName = $Server | Select-Object -ExpandProperty ServerName
                $Status = $Server | Select-Object -ExpandProperty Status
                Write-CMLogEntry -Value "Identified [Server=$ServerName] [MaintenanceModeStatus=$Status]" -Severity 3
            }
            exit 1
        }
        else {
            Write-CMLogEntry "Validated that no servers are in maintenance mode"
        }
        $MailDB = foreach ($MailboxServerName in (Get-MailboxServer | Select-Object -ExpandProperty Name)) {
            Get-MailboxDatabaseCopyStatus -Server $MailboxServerName
        }
        $DBStatus = Compare-Object -ReferenceObject ($MailDB | Select-Object -ExpandProperty Status -Unique) -DifferenceObject @('Mounted', 'Healthy')
        if ($null -eq $DBStatus) {
            Write-CMLogEntry "Validated that all database are in a Mounted or Healthy state"
        }
        else {
            Write-CMLogEntry -Value "FAILURE::Found at least one DB that is NOT in a Mounted or Healthy state - exiting" -Severity 3
            throw "FAILURE::Found at least one DB that is NOT in a Mounted or Healthy state - exiting"
        }
        #endregion make sure we are ok to proceed!

        #region select a random 'target server' that is not in maintenance mode so that we can Redirect-Message to the server
        $TargetServer = $ExchEnvStatus | Where-Object { $_.ServerName -ne $ComputerName -and $_.Status -eq 'MaintenanceModeOff' } | Select-Object -ExpandProperty ServerName | Get-Random
        #endregion select a random 'target server' that is not in maintenance mode so that we can Redirect-Message to the server

        #region move exchange server into maintenance mode and validate
        #region set
        Update-DBServerStatus -LastStatus "Putting into Maintenance Mode"
        Write-CMLogEntry "Putting $ComputerName into maintenance mode"
        Set-ExchMaintenanceMode -ComputerName $ComputerName -On -TargetServer $TargetServer -RemotingCredential $RemotingCreds
        #endregion set

        #region validate
        $newLoopActionSplat = @{
            ScriptBlock     = {
                $script:Status = Get-ExchMaintenanceMode -ComputerName $script:ComputerName -RemotingCredential $script:RemotingCreds
            }
            ExitCondition   = {
                $script:Status -eq 'MaintenanceModeOn'
            }
            IfTimeoutScript = {
                Write-CMLogEntry -Value "Failed to validate that $script:ComputerName is in maintenance mode" -Severity 3
                throw "Failed to validate that $script:ComputerName is in maintenance mode."
            }
            LoopDelayType   = 'Seconds'
            LoopDelay       = 30
            IfSucceedScript = {
                Write-CMLogEntry "$script:ComputerName is verified to be in maintenance mode"
            }
            LoopTimeout     = 5
            LoopTimeoutType = 'Minutes'
        }
        Update-DBServerStatus -LastStatus "Validating Maintenance Mode"
        Write-CMLogEntry "Starting the check for maintenance mode on $ComputerName"
        New-LoopAction @newLoopActionSplat
        #endregion validate
        #endregion move exchange server into maintenance mode and validate

        #region stop and disable services
        $ServicesToStop = @('Microsoft Exchange Frontend Transport', 'IMAP4')
        Update-DBServerStatus -LastStatus "Stopping and Disabling Services - $($ServicesToStop -join ';')"
        Write-CMLogEntry "Stopping and Disabling Services - $($ServicesToStop -join ';')"
        foreach ($ServiceString in $ServicesToStop) {
            Remove-Variable -Name Service -ErrorAction SilentlyContinue
            $Service = Get-WmiObject -ComputerName $FQDN -Class Win32_Service -Filter "(Name LIKE '%$ServiceString%' or Caption LIKE '%$ServiceString%') AND State = 'Running'" -Credential $RemotingCreds
            if ($Service) {
                $ServiceName = $Service | Select-Object -ExcludeProperty Name
                Write-CMLogEntry "Service identified [Name=$ServiceName] on [ComputerName=$ComputerName]"
                Write-CMLogEntry "Stopping $ServiceName"
                $Result = $Service.StopService() | Select-Object -ExpandProperty ReturnValue
                if ($Result -ne 0) {
                    Write-CMLogEntry -Value "Failed to stop $ServiceName" -Severity 2
                    throw "Failed to stop $ServiceName"
                }
                else {
                    Write-CMLogEntry "$ServiceName stopped"
                }
                Write-CMLogEntry "Disabling $ServiceName"
                $Result = $Service.ChangeStartMode("Disabled") | Select-Object -ExpandProperty ReturnValue
                if ($Result -ne 0) {
                    Write-CMLogEntry -Value "Failed to disable $ServiceName" -Severity 2
                    throw "Failed to disable $ServiceName"
                }
                else {
                    Write-CMLogEntry "$ServiceName disable"
                }
            }
            else {
                Write-CMLogEntry -Value "Failed to identify a running service that matches $ServiceString" -Severity 2
            }
        }
        #endregion stop and disable services

        $ResultStatus = 'Success'
    }
    catch {
        # Catch any errors thrown above here, setting the result status and recording the error message to return to the activity for data bus publishing
        $ResultStatus = "Failed"
        $ErrorMessage = $error[0].Exception.Message
        Write-CMLogEntry "Exception caught during action [$global:CurrentAction]: $ErrorMessage" -Severity 3
        $FailingCommand = $Error[0].InvocationInfo.MyCommand | Select-Object -ExpandProperty Name
        Update-DBServerStatus -LastStatus "Failed to set server into maintenance mode - Command: $FailingCommand"
    }
    finally {
        # Always do whatever is in the finally block. In this case, adding some additional detail about the outcome to the trace log for return
        if ($ErrorMessage.Length -gt 0) {
            $ResultStatus = 'Failed'
            Write-CMLogEntry "Exiting script with result [$ResultStatus] and error message [$ErrorMessage]" -Severity 3
        }
        else {
            Write-CMLogEntry "Exiting script with result [$ResultStatus]"
            Update-DBServerStatus -LastStatus 'Server in Maintence Mode'
        }
        if ($CIMSession) {
            $CIMSession.Close()
        }
    }
    # Record end of activity script process
    Update-DBServerStatus -Status "Finished $ScriptName"
    Update-DBServerStatus -Stage 'End' -Component $ScriptName
    Write-CMLogEntry "Script finished"
}