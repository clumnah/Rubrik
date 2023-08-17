# Script was to migrate a database from a legacy SQL Server to a modern SQL Server and place the database into an Availability Group. 
# Essentially we took one database on one server and migrated it to multiple servers. 
# This script requires that you have already set up log shipping in Rubrik from the source to all of the replica servers involved in the Availability Group

$SourceAGName = 'rp-sql19ags-g1'
$TargetAGName = 'test'
# $DatabaseName = 'AdventureWorks2019'
$DatabaseName = 'AdventureWorksDW2019'
$RemoveLogShipping = $true

$ConnectRubrik = @{
    Server = op read op://Rubrik/perfpod-cdm02_ServiceAccount/hostname
    id = op read op://Rubrik/perfpod-cdm02_ServiceAccount/username
    Secret = op read op://Rubrik/perfpod-cdm02_ServiceAccount/credential
    # Token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJjYjgxOGVjMC04MDc3LTRlMzItODZmMC0zYjZhZGQ3Y2ZkNGJfY2hyaXMubHVtbmFoQHBlcmYucnVicmlrLmNvbVtTU09dIiwiaXNNZmFSZW1lbWJlclRva2VuIjpmYWxzZSwiaXNzIjoiY2I4MThlYzAtODA3Ny00ZTMyLTg2ZjAtM2I2YWRkN2NmZDRiIiwiaXNSZWR1Y2VkU2NvcGUiOmZhbHNlLCJpYXQiOjE2ODM5MjE0NjQsImp0aSI6ImY1NjcwODFkLTJhNDUtNDk5Yy04ZWRhLTU3NDg3OTU4N2Y2MiJ9.De_XpRIhDLEe64wDv_7Jma8QJFnWNbvLtux9yCKYc6k"
}
###############################################################################################################################################################################
Connect-Rubrik @ConnectRubrik

$SourceRubrikAG = Get-RubrikAvailabilityGroup -GroupName $SourceAGName 
$TargetRubrikAG = Get-RubrikAvailabilityGroup -GroupName $TargetAGName 


# $SourceAGDetails = (Invoke-RubrikRESTCall -Endpoint "mssql/hierarchy/$($SourceRubrikAG.id)/children" -Method GET  -Verbose).data | Where-Object {$_.name -eq $DatabaseName}
$TargetAGDetails = (Invoke-RubrikRESTCall -Endpoint "mssql/hierarchy/$($TargetRubrikAG.id)/children" -Method GET ).data[0]

$GetRubrikDatabase = @{
    AvailabilityGroupID = $SourceRubrikAG.id
    Name = $DatabaseName
    Relic = $false
}
$SourceRubrikDatabase = Get-RubrikDatabase @GetRubrikDatabase

$GetRubrikLogShipping = @{
    PrimaryDatabaseId = $SourceRubrikDatabase.id
}
$RubrikLogShipping = Get-RubrikLogShipping @GetRubrikLogShipping


#region Start Migration Process
Write-Host "- Take final transaction log backup of $($DatabaseName) on $($SourceAGName)" -ForegroundColor Green
$RubrikRequest = New-RubrikLogBackup -id $SourceRubrikDatabase.id
Get-RubrikRequest -id $RubrikRequest.id -Type mssql -WaitForCompletion


$latestRecoveryPoint = ((Get-RubrikDatabase -id $SourceRubrikDatabase.id).latestRecoveryPoint)
Write-Host "- The Latest Recovery Point of $($DatabaseName) on $($SourceAGName) is now $($latestRecoveryPoint)" -ForegroundColor Green


Foreach ($LogShippedDB in $RubrikLogShipping){
    Write-Host "- Applying all transaction logs from $($SourceAGName).$($DatabaseName) to $($LogShippedDB.location)" -ForegroundColor Green
    Set-RubrikLogShipping -id $LogShippedDB.id -state $LogShippedDB.state     
}

Write-Host "- Wait for all of the logs to be applied" -ForegroundColor Green
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

Disconnect-Rubrik
$TargetPrimary = $TargetAGDetails.replicas | Where-Object {$_.availabilityInfo.role -eq 'PRIMARY'}
if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
    $TargetSQLServerInstance = "$($TargetPrimary.rootProperties.rootName)"
}else{
    $TargetSQLServerInstance = "$($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)"
}

write-host "- Bring $($Databasename) online on $($TargetPrimary.rootProperties.rootName)" -ForegroundColor Green
$Query = "RESTORE DATABASE [$($Databasename)] WITH RECOVERY"
Invoke-DbaQuery -sqlinstance  $TargetSQLServerInstance -Query $Query
# Invoke-Sqlcmd -ServerInstance $TargetSQLServerInstance -Query $Query

Write-Host "- Adding $($DatabaseName) to $($TargetAGName) on $($TargetPrimary.rootProperties.rootName)" -ForegroundColor Green
$Query = "ALTER AVAILABILITY GROUP [$($TargetAGName)] ADD DATABASE [$($DatabaseName)];"
Invoke-DbaQuery -SqlInstance $TargetPrimary.rootProperties.rootName -Query $Query

# if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
#     Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($TargetPrimary.rootProperties.rootName)" -ForegroundColor Green
#     Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($TargetPrimary.rootProperties.rootName)\DEFAULT\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName     
# }else{
#     Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)" -ForegroundColor Green
#     Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($TargetPrimary.rootProperties.rootName)\$($TargetPrimary.instanceName)\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName     
# }   


#Add all replicas to the availability group and then remove log shipping. 
foreach($Replica in $TargetAGDetails.replicas | Where-Object {$_.availabilityInfo.role -eq 'SECONDARY'}){  
    Write-Host "- Adding $($DatabaseName) to $($TargetAGName) on $($Replica.rootProperties.rootName)" -ForegroundColor Green
    $Query = "ALTER DATABASE [$($DatabaseName)] SET HADR AVAILABILITY GROUP = [$($TargetAGName)];"
    Invoke-DbaQuery -SqlInstance $replica.rootProperties.rootName -Query $Query
    # if ($TargetPrimary.instanceName -eq 'MSSQLSERVER'){
    #     Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($Replica.rootProperties.rootName)" -ForegroundColor Green
    #     Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($Replica.rootProperties.rootName)\DEFAULT\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName
    # }else{
    #     Write-Host "Adding $($DatabaseName) to $($TargetAGName) on $($Replica.rootProperties.rootName)\$($Replica.instanceName)" -ForegroundColor Green
    #     Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$($Replica.rootProperties.rootName)\$($Replica.instanceName)\AvailabilityGroups\$($TargetAGName)" -Database $DatabaseName        
    # }  
}
