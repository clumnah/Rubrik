<#
.SYNOPSIS
    Rubrik Cross Site AG Failover
.DESCRIPTION
    Rubrik Cross Site AG Failover script. 
    This is to be used at your own risk and is not supported by Rubrik. This meant to be used as an example to show how you would automate the protection and unprotection of an AG that crosses
    data centers. This current setup is not supported by Rubrik. The only way to achieve protection of an AG at this time is to protect the group in Rubrik in the site that you want backups to happen on. 
    The other site should have the group set to a DO NOT PROTECT or UNPROTECTED state. This script attempts to automate this process by doing the following.

.EXAMPLE
    PS C:\> <example usage>
    Explanation of what the example does
.NOTES
    This is to be used at your own risk and is not supported by Rubrik. This meant to be used as an example to show how you would automate the protection and unprotection of an AG that crosses
    data centers. This current setup is not supported by Rubrik. The only way to achieve protection of an AG at this time is to protect the group in Rubrik in the site that you want backups to happen on. 
    The other site should have the group set to a DO NOT PROTECT or UNPROTECTED state. This script attempts to automate this process by doing the following.

    1. An alert is created on each SQL Server Replica that monitors for the event ID of 1480. This is the event id for a database switching roles. This alert will fire for each database in an AG. 
        The alert's response is to fire a SQL Server Agent Job. This job runs this script to protect or unprotect the AG on the Rubrik Cluster provided.
    2. The SQL Server Agent Job is configured to have 2 steps. 
        1. Check if the job has been in the last 5 minutes. If the job has been run in the last 5 minutes, the job will end gracefully. No action will be taken. This is to prevent the same API call being run
            against the Rubrik Cluster, which would cause confusion and a potential race condition. 
        2. If the job has not been run in the last 5 minutes, this script will be run to configure protection in Rubrik. 



    The overall logic of the script is as follows:
    - Get the list of AG Failovers that have happened
    - For each AG Failover do the following
        - Get information about the AG that failed over
        - If the backup preference is the primary
            - if the sql instance is the primary
                - check if the sql server is registered to the Rubrik Cluster
                - if it is registered
                    - protect the AG on the Rubrik Cluster
            - if it is not secondary
                - unprotect the group
        - if the backup preference is the secondary
            - get the highest prioritized replica 
                - if the highest prioritized replica is registered
                    - protect the group
                - if not registered
                    - unprotect the group

#>
#Requires -Module dbatools, sqlserver, rubrik
[CmdletBinding()]
param (
    [Parameter()]
    [string]$SQLInstance,
    [Parameter()]
    [string]$SLAName,
    [Parameter()]
    [string]$RubrikServer,
    [Parameter()]
    [string]$RubrikToken,
    [Parameter()]
    [int]$logBackupFrequencyInSeconds = 3600,
    [Parameter()]
    [int]$logRetentionHours = 168
)
function GetSQLInstanceFromRubrik{
    param (
        [Parameter(Mandatory)]
        [string]$SQLInstance
    )
    if ($SQLInstance.IndexOf("\") -gt 0){
        Write-Host "Getting information about $($SQLInstance) from $($Global:RubrikConnection.Server)"
        $HostName = $SQLInstance.Substring(0,$SQLInstance.IndexOf("\"))
        $Instance = $SQLInstance.Substring($SQLInstance.IndexOf("\")+1,($SQLInstance.Length - $SQLInstance.IndexOf("\")) -1  )
        $RubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance $SQLInstance
        if ([bool]($RubrikSQLInstance.PSobject.Properties.name -match "id") -eq $false){
            $FQDN = ([System.Net.Dns]::GetHostByName(($HostName))).hostname
            $RubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance "$($FQDN)\$($Instance)"
            $SQLInstance = "$($FQDN)\$($Instance)"
        }
    }
    else{
        Write-Host "Getting information about $($SQLInstance) from $($Global:RubrikConnection.Server)"
        $HostName = $SQLInstance
        $Instance = "DEFAULT"
        $RubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance $SQLInstance
        if ([bool]($RubrikSQLInstance.PSobject.Properties.name -match "id") -eq $false){
            $FQDN = ([System.Net.Dns]::GetHostByName(($SQLInstance))).hostname
            $RubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance $FQDN
        }
    }
    $RubrikSQLInstance
}
function ProtectAGInRubrik{
    param (
        [Parameter(Mandatory)]
        [string]$AvailabilityGroup,
        [Parameter(Mandatory)]
        [string]$SLAName,
        [Parameter(Mandatory)]
        [int]$logBackupFrequencyInSeconds,
        [Parameter(Mandatory)]
        [int]$logRetentionHours
    )
    
    
    $Query = @{
        'primary_cluster_id'='local' 
    }
    $RubrikAvailabilityGroup = (Invoke-RubrikRESTCall -Endpoint "mssql/availability_group" -Method GET -Query $Query).data | Where-Object {$_.name -eq $AvailabilityGroup}
    
    $RubrikSLA = Get-RubrikSLA -Name $SLAName
    # TODO: IF No SLA is found, error out gracefully!
    $Body = @{
        "logBackupFrequencyInSeconds" = $($logBackupFrequencyInSeconds)
        "logRetentionHours" = $($logRetentionHours)
        "copyOnly" = $false
        "configuredSlaDomainId" = "$($RubrikSLA.id)"
        "ids" = @(
            "$($RubrikAvailabilityGroup.id)"
        )
    }
    Write-Host "Protecting $($AvailabilityGroup) on $($Global:RubrikConnection.Server) based on backup preferences of AG"
    Invoke-RubrikRESTCall -Method POST -Endpoint "mssql/sla_domain/assign" -Body $Body -api 2
}
function UnProtectAGInRubrik{
    param (
        [Parameter(Mandatory)]
        [string]$AvailabilityGroup
    )
    $Query = @{
        'primary_cluster_id'='local' 
    }
    $RubrikAvailabilityGroup = (Invoke-RubrikRESTCall -Endpoint "mssql/availability_group" -Method GET -Query $Query).data | Where-Object {$_.name -eq $AvailabilityGroup}
    $Body = @{
        "configuredSlaDomainId" = "UNPROTECTED"
        "ids" = @(
            "$($RubrikAvailabilityGroup.id)"
        )
        "existingSnapshotRetention" = "RetainSnapshots"
    }
    Write-Host "Unprotecting $($AvailabilityGroup) on $($Global:RubrikConnection.Server) based on backup preferences of AG"
    Invoke-RubrikRESTCall -Method POST -Endpoint "mssql/sla_domain/assign" -Body $Body -api 2 -verbose
}
#region Find the last time the AGs failed over on the SQL instance
Write-Output "Getting the last time the AGs failed over on $($SQLInstance)"
$AGFailovers = Get-DbaXESession -SqlInstance $SqlInstance -Session alwayson_health |
    Read-DbaXEFile |
    Where-Object name -eq 'availability_replica_state_change' | 
    Select-Object availability_group_name, availability_replica_name, timestamp, previous_state, current_state | 
    Group-Object -Property availability_group_name | 
    Sort-Object -Property timestamp -Descending 
#endregion

foreach ($AGFailover in $AGFailovers){
    $AvailabilityGroup = $AGFailover.Group.availability_group_name | Select-Object -First 1
    Write-Host "Getting information about Availability Group:$($AvailabilityGroup) from SQL Replica:$($SQLInstance)"

    $AGInfo = Get-DbaAvailabilityGroup -SqlInstance $SQLInstance -AvailabilityGroup $AvailabilityGroup
    
    $AGReplicaRole = ($AGinfo.AvailabilityReplicas | Where-Object {$_.Name -eq $SQLInstance}).Role
    Write-Host "$($SQLInstance) is currently in the $($AGReplicaRole) role and the backup preferense states the backup should be done off of a $($AGInfo.AutomatedBackupPreference) replica."

    Connect-Rubrik -Server $RubrikServer -Token $RubrikToken | Out-Null
   
    if ($AGInfo.AutomatedBackupPreference -eq 'Primary'){ 
        Write-Host "Checking to see if $($SQLInstance) is registered on $($RubrikServer)" -ForegroundColor DarkCyan
        $RubrikSQLInstance = GetSQLInstanceFromRubrik -SQLInstance $SQLInstance
        if ([bool]($RubrikSQLInstance.PSobject.Properties.name -match "id") -eq $true){
            if ($AGReplicaRole -eq 'Primary'){
                ProtectAGInRubrik -AvailabilityGroup $AvailabilityGroup -SLAName $SLAName -logBackupFrequencyInSeconds $logBackupFrequencyInSeconds -logRetentionHours $logRetentionHours
            }else {
                UnProtectAGInRubrik -AvailabilityGroup $AvailabilityGroup
            }
        }else {
            Write-Host "$($SQLInstance) was not found on $($Global:RubrikConnection.Server). No change is being made"
        }
    }else{
        $SecondaryReplica = $AGInfo.AvailabilityReplicas | Where-Object {$_.Role -ne 'Primary'} | Sort-Object -Property BackupPriority -Descending | Select-Object -First 1
        $SecondaryReplica.AvailabilityReplicas | Format-List *
        Write-Host "Highest Prioritized replica is $($SecondaryReplica.Name)"
        Write-Host "SQL Server that I am: $($SQLInstance)"
        $SecondaryReplica | Format-List *

        if ($SQLInstance -eq $SecondaryReplica.Name){       
            $RubrikSQLInstance = GetSQLInstanceFromRubrik -SQLInstance $SQLInstance
            
            if ([bool]($RubrikSQLInstance.PSobject.Properties.name -match "id") -eq $true){
                # if ($AGReplicaRole -eq 'Secondary'){
                    ProtectAGInRubrik -AvailabilityGroup $AvailabilityGroup -SLAName $SLAName -logBackupFrequencyInSeconds $logBackupFrequencyInSeconds -logRetentionHours $logRetentionHours
                # }else {
    
                # }
            }
        }else {
            UnProtectAGInRubrik -AvailabilityGroup $AvailabilityGroup
        }
    }
}
            
            
            
            Disconnect-Rubrik