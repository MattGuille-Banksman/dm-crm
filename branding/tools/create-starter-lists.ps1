# Creates the starter contact lists (once, by name). Run after the CRM update,
# when the crm_segment_build_filter workflow exists to write their filters.
#
# Usage: powershell -File create-starter-lists.ps1 -BaseUrl <url> -TokenFile <file>

param(
    [Parameter(Mandatory = $true)] [string] $BaseUrl,
    [Parameter(Mandatory = $true)] [string] $TokenFile,
    [string] $NamespaceSlug = 'crm'
)

$ErrorActionPreference = 'Stop'
$token = (Get-Content -Raw $TokenFile).Trim()
$headers = @{ Authorization = "Bearer $token" }
$api = "$BaseUrl/api/compose"

function Invoke-Api($method, $path, $body) {
    $params = @{ Method = $method; Uri = "$api$path"; Headers = $headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $body) {
        $json = $body | ConvertTo-Json -Depth 30 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
    }
    $res = Invoke-RestMethod @params
    if ($res.error) { throw "API error on $method ${path}: $($res.error.message)" }
    return $res.response
}

$ns = (Invoke-Api GET "/namespace/?slug=$NamespaceSlug" $null).set | Where-Object { $_.slug -eq $NamespaceSlug } | Select-Object -First 1
if (-not $ns) { throw "Namespace '$NamespaceSlug' not found" }
$nsID = $ns.namespaceID

function Get-Modules { (Invoke-Api GET "/namespace/$nsID/module/?limit=200" $null).set }
function Find-Module($handle) { Get-Modules | Where-Object { $_.handle -eq $handle } | Select-Object -First 1 }

# --- starter lists -------------------------------------------------------------
# Created once (by name); the list filter is written by crm_segment_build_filter
$segmentID = (Find-Module 'Segment').moduleID
$existing = @((Invoke-Api GET "/namespace/$nsID/module/$segmentID/record/?limit=500" $null).set | ForEach-Object {
    ($_.values | Where-Object { $_.name -eq 'name' }).value
})
$starter = @(
    @{ name = 'All contacts'; category = 'Marketing'; description = 'Every contact in the CRM.' },
    @{ name = 'Leads'; category = 'Sales'; match_lifecycle = @('Lead', 'MQL', 'SQL'); description = 'Contacts at lead, MQL or SQL stage.' },
    @{ name = 'Customers'; category = 'Customers'; match_lifecycle = @('Customer') },
    @{ name = 'Engaged in the last 30 days'; category = 'Marketing'; match_engagement = 'Opened recently'; description = 'Opened a marketing email in the last 30 days.' },
    @{ name = 'Never emailed'; category = 'Marketing'; match_engagement = 'Not emailed'; description = 'Has never been sent a marketing email.' },
    @{ name = 'Has an open deal'; category = 'Sales'; match_deals = 'Open deal' }
)
foreach ($s in $starter) {
    if ($existing -contains $s.name) { continue }
    $values = @(@{ name = 'list_type'; value = 'Active' })
    foreach ($k in $s.Keys) {
        foreach ($v in @($s[$k])) { $values += @{ name = $k; value = "$v" } }
    }
    [void](Invoke-Api POST "/namespace/$nsID/module/$segmentID/record/" @{ values = $values })
    Write-Host "+ list $($s.name)"
}
