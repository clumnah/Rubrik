$url = "https://archive.org/details/stackexchange"
$destPath  =  '~/Downloads/'
$response  = Invoke-WebRequest -Uri $url -Method GET
$files = @($response | Select-Object -ExpandProperty Links | Where-Object href -Like *7z | Select-Object -ExpandProperty href -skip 5)
# foreach( $file in $files ) {
#     $FileName = Split-Path $File -Leaf
#     $FileName
#     Invoke-WebRequest -Uri ("https://archive.org$($file)") -Method GET -OutFile "$($destPath)$($FileName)" | Out-Null
# }

$Files | Foreach-Object -ThrottleLimit 5 -Parallel {
  #Action that will run in Parallel. Reference the current object via $PSItem and bring in outside variables with $USING:varname
  $File = $_
  $FileName = Split-Path $File -Leaf
  $FileName
  Invoke-WebRequest -Uri ("https://archive.org$($file)") -Method GET -OutFile "$($Using:destPath)$($FileName)" | Out-Null
}