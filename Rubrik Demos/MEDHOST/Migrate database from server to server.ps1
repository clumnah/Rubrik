# Script was to migrate a database from a legacy SQL Server to a modern SQL Server and place the database into an Availability Group. 
# Essentially we took one database on one server and migrated it to multiple servers. 
# This script requires that you have already set up log shipping in Rubrik from the source to all of the replica servers involved in the Availability Group
import-module Rubrik -Force
$SourceSQLInstance = 'rp-sql16s-001.perf.rubrik.com'
$TargetSQLInstance = 'rp-sql19s-001.perf.rubrik.com'
$DatabaseName = 'AdventureWorks2016'
$RemoveLogShipping = $true
$ClientID = op read op://Rubrik/perfpod-cdm02_ServiceAccount/username
$ClientSecret = op read op://Rubrik/perfpod-cdm02_ServiceAccount/credential
$AccessTokenURI = op read op://Rubrik/perfpod-cdm02_ServiceAccount/hostname
###############################################################################################################################################################################
Connect-Rubrik -Server $AccessTokenURI -id $ClientID -Secret $ClientSecret
$SourceRubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance $SourceSQLInstance
# $TargetRubrikSQLInstance = Get-RubrikSQLInstance -ServerInstance $TargetSQLInstance


# $SourceAGDetails = (Invoke-RubrikRESTCall -Endpoint "mssql/hierarchy/$($SourceRubrikAG.id)/children" -Method GET  -Verbose).data | Where-Object {$_.name -eq $DatabaseName}
# $TargetAGDetails = (Invoke-RubrikRESTCall -Endpoint "mssql/hierarchy/$($TargetRubrikAG.id)/children" -Method GET  -Verbose).data[0]

$GetRubrikDatabase = @{
    InstanceID = $SourceRubrikSQLInstance.id
    Name = $DatabaseName
    Relic = $false
}
$SourceRubrikDatabase = Get-RubrikDatabase @GetRubrikDatabase

$GetRubrikLogShipping = @{
    PrimaryDatabaseId = $SourceRubrikDatabase.id
}
$RubrikLogShipping = Get-RubrikLogShipping @GetRubrikLogShipping


#region Start Migration Process
Write-Host "Take final transaction log backup of $($DatabaseName) on $($SourceSQLInstance)" -ForegroundColor Green
$RubrikRequest = New-RubrikLogBackup -id $SourceRubrikDatabase.id
Get-RubrikRequest -id $RubrikRequest.id -Type mssql -WaitForCompletion


$latestRecoveryPoint = ((Get-RubrikDatabase -id $SourceRubrikDatabase.id).latestRecoveryPoint)
Write-Host "The Latest Recovery Point of $($DatabaseName) on $($SourceSQLInstance) is now $($latestRecoveryPoint)" -ForegroundColor Green


Foreach ($LogShippedDB in $RubrikLogShipping){
    Write-Host "Applying all transaction logs from $($SourceSQLInstance).$($DatabaseName) to $($LogShippedDB.location)" -ForegroundColor Green
    Set-RubrikLogShipping -id $LogShippedDB.id -state $LogShippedDB.state     
}

Write-Host "Wait for all of the logs to be applied" -ForegroundColor Green
Foreach ($LogShippedDB in $RubrikLogShipping){
    do{
        $CheckRubrikLogShipping = Get-RubrikLogShipping -id $LogShippedDB.id
        $lastAppliedPoint = ($CheckRubrikLogShipping.lastAppliedPoint)
        Start-Sleep -Seconds 1
    } until ($latestRecoveryPoint -eq $lastAppliedPoint)
    if ($RemoveLogShipping -eq $true){
        Write-Host "Removing Log Shipping from $($LogShippedDB.location)" -ForegroundColor Green
        Remove-RubrikLogShipping -id $LogShippedDB.id
    }
}
write-host "Take $($Databasename) offline on $($SourceSQLInstance)" -ForegroundColor Green
$Query = "ALTER DATABASE [$($Databasename)] SET OFFLINE"
# Invoke-Sqlcmd -ServerInstance $TargetSQLInstance -Query $Query -Debug
Invoke-DbaQuery -SqlInstance $SourceSQLInstance -Query $Query


write-host "Bring $($Databasename) online on $($TargetSQLInstance)" -ForegroundColor Green
$Query = "RESTORE DATABASE [$($Databasename)] WITH RECOVERY"
# Invoke-Sqlcmd -ServerInstance $TargetSQLInstance -Query $Query -Debug
Invoke-DbaQuery -SqlInstance $TargetSQLInstance -Query $Query


Disconnect-Rubrik
break
$TargetPrimary = $TargetAGDetails.replicas | Where-Object {$_.availabilityInfo.role -eq 'PRIMARY'}
if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
    $TargetSQLServerInstance = "$($TargetPrimary.rootProperties.rootName)"
}else{
    $TargetSQLServerInstance = "$($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)"
}

write-host "Bring $($Databasename) online on $($TargetPrimary.rootProperties.rootName)" -ForegroundColor Green
$Query = "RESTORE DATABASE [$($Databasename)] WITH RECOVERY"
Invoke-Sqlcmd -ServerInstance $TargetSQLServerInstance -Query $Query


if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
    Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($TargetPrimary.rootProperties.rootName)" -ForegroundColor Green
    Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($TargetPrimary.rootProperties.rootName)\DEFAULT\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName     
}else{
    Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)" -ForegroundColor Green
    Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName     
}   


#Add all replicas to the availability group and then remove log shipping. 
foreach($Replica in $TargetAGDetails.replicas | Where-Object {$_.availabilityInfo.role -eq 'SECONDARY'}){  
    if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
        Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($Replica.rootProperties.rootName)" -ForegroundColor Green
        Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($Replica.rootProperties.rootName)\DEFAULT\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName
    }else{
        Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($Replica.rootProperties.rootName)\$($Replica.instanceName)" -ForegroundColor Green
        Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($Replica.rootProperties.rootName)\$($Replica.instanceName)\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName        
    }  
}