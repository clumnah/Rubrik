<#
.SYNOPSIS
    Configures a database on a SQL Server to retain the log backup locally for a set period of time.
.DESCRIPTION
    Rubrik 9.0 introduces a feature called Host Log Retention. This feature enables DBAs to use Rubrik backups with other 3rd parth applications like Delphix or Qlik. 
    Those applications typically read msdb for the backup history which also stores the location of the backup. By default, log backups taken by Rubrik are done using 
    Microsoft's VDI function. This streams the log backup to the Rubrik device instead of storing it locally. By doing this, you end up with a faster backup, but at the sake
    of msdb having a device GUID for a location vs having a path and file name. 

    Enabling this feature allows log backups to be written to local disk first. Rubrik will automatically ingest these backups and remove them local disk based upon the 
    host log retention value. 

    No Output is given at this time. 

.NOTES

.LINK

.EXAMPLE
    Enable-RSCMssqlHostLogRetention -SQLServerInstance "sql1.rubrikdemo.com" \
        -DatabaseName = "Accounting" \
        -HostLogRetentionInSeconds = 3600 \
        -Client -924hasjlnnblasbdjklfb;asdf \
        -ClientSecret 087q32908569y iuahsijgbashig8w9eadbadfsg \
        -AccessTokenURI "https://rubrikdemo.my.rubrik.com/api/client_token"

    Script will run against a Rubrik environment and configure the Accounting database on sql1.rubrikdemo.com to have log backups retained on local disk for 3600 seconds
    or 1 hour.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [String]$SQLServerInstance = "sx2-sql19ag-1a.rubrikdemo.com",

    [Parameter(Mandatory = $true)]
    [String]$DatabaseName = "Amsterdam", 

    [Parameter()]
    [Int]$HostLogRetentionInSeconds = 60,

    [Parameter()]
    [String]$ClientID = (op read "op://Rubrik/Gaia Next Service Account/username"),

    [Parameter()]
    $ClientSecret = (ConvertTo-SecureString (op read "op://Rubrik/Gaia Next Service Account/credential") -AsPlainText -Force),

    [Parameter()]
    [String]$AccessTokenURI = (op read "op://Rubrik/Gaia Next Service Account/hostname")

)
Import-Module RubrikSecurityCloud

Connect-Rsc -Server $AccessTokenURI -ClientId $ClientID -ClientSecret $ClientSecret

#region Get SQL Server Instance ID
$filter = @(
    @{
        "field" = "NAME"
        "texts" = "$($SQLServerInstance)"
    }
)
$inputs = Invoke-RscQueryMssql -TopLevelDescendant -GetInputs
$inputs.Arg.filter = $Filter
$RSCMSSQLInventory = Invoke-RscQueryMssql -TopLevelDescendant -Arg $inputs.Arg
$RSCSQLInstance = $RSCMSSQLInventory.Nodes.PhysicalChildConnection.Nodes | Where-Object {$_.ObjectType -eq "MSSQL_INSTANCE"}
# $RSCSQLInstance
#endregion

#region Get Database Information
$query = "query GetMSSQLDatabase {
	mssqlInstance(fid: `"$($RSCSQLInstance.Id)`") {
		id
		name
		descendantConnection(filter: {field: NAME, texts: `"$($DatabaseName)`"}) {
			nodes {
				... on MssqlDatabase {
					id
					name
                    effectiveSlaDomain {
                        id
                        name
                    }
				}
			}
		}
	}
}"
$RSCDatabase = (Invoke-Rsc -Query $query).DescendantConnection.nodes
#endregion

#region Set Host Log Retention Values
$query = "mutation AssignMssqlSlaDomainPropertiesAsync(`$input: AssignMssqlSlaDomainPropertiesAsyncInput!) {
    assignMssqlSlaDomainPropertiesAsync(input: `$input) {
      items {
        isPendingSlaDomainRetentionLocked
        objectId
        pendingSlaDomainId
        pendingSlaDomainName
      }
    }
  }
  "
$Variables = @{
    input = @{
        updateInfo = @{
            ids = @("$($RSCDatabase.id)")
            existingSnapshotRetention =  "EXISTING_SNAPSHOT_RETENTION_RETAIN_SNAPSHOTS"
            mssqlSlaPatchProperties = @{
                mssqlSlaRelatedProperties = @{
                    hostLogRetention = $HostLogRetentionInSeconds
                    copyOnly = $false
                    hasLogConfigFromSla = $false
                    # logBackupFrequencyInSeconds = 0
                }
                configuredSlaDomainId = "$($RSCDatabase.EffectiveSlaDomain.id)"
            }
        }
    }
}
Invoke-Rsc -Query $query -Variables $Variables
#endregion