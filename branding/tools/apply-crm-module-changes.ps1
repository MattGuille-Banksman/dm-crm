# Applies the DM-CRM module changes (segments, contact rollups, email
# intelligence and HTML template fields) to an existing instance through
# the Compose REST API.
#
# The envoy importer cannot do this safely on an instance that already has
# the CRM: when it creates a new module whose fields share names with fields
# in other modules (owner, name, description...), it matches and moves those
# existing fields. This script only adds fields and adjusts options; it
# never removes or renames anything, and it is safe to run more than once.
#
# Usage:
#   powershell -File apply-crm-module-changes.ps1 -BaseUrl http://localhost:18080 -TokenFile token.txt
# Get a token with:
#   docker compose exec server corteza-server auth jwt <admin email>

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

function F($name, $kind, $label, $options = @{}, $required = $false, $default = $null, $multi = $false) {
    $f = [ordered]@{ name = $name; kind = $kind; label = $label; options = $options; isRequired = $required; isMulti = $multi }
    if ($null -ne $default) { $f.defaultValue = @(@{ value = $default }) }
    return $f
}
function Opts([string[]] $values, [hashtable] $texts = @{}) {
    @($values | ForEach-Object { [ordered]@{ value = $_; text = $(if ($texts.ContainsKey($_)) { $texts[$_] } else { $_ }) } })
}
function RecordOpts($moduleID, $labelField, [string[]] $queryFields) {
    @{ moduleID = "$moduleID"; labelField = $labelField; queryFields = $queryFields; selectType = 'default' }
}

function Ensure-Module($handle, $name, $fields) {
    $existing = Find-Module $handle
    if ($existing) { Write-Host "= $handle exists"; return $existing }
    # field order is the array order
    $body = [ordered]@{
        name   = $name
        handle = $handle
        meta   = @{}
        fields = @($fields)
    }
    $created = Invoke-Api POST "/namespace/$nsID/module/" $body
    Write-Host "+ created module $handle"
    return $created
}

# Adds missing fields (by name) and applies $tweak to the module afterwards
function Update-Module($handle, $newFields, [scriptblock] $tweak = $null) {
    $mod = Find-Module $handle
    if (-not $mod) { throw "Module $handle not found" }
    $mod = Invoke-Api GET "/namespace/$nsID/module/$($mod.moduleID)" $null

    $fields = [System.Collections.ArrayList]@($mod.fields)
    $names = @($fields | ForEach-Object { $_.name })
    $added = @()
    foreach ($nf in $newFields) {
        if ($names -contains $nf.name) { continue }
        [void]$fields.Add([pscustomobject]$nf)
        $added += $nf.name
    }
    $mod.fields = @($fields)
    if ($tweak) { & $tweak $mod }

    [void](Invoke-Api POST "/namespace/$nsID/module/$($mod.moduleID)" $mod)
    if ($added.Count) { Write-Host "~ $handle + $($added -join ', ')" } else { Write-Host "~ $handle (options only)" }
}

$contact = Find-Module 'Contact'
$userOpts = @{ presetWithAuthenticated = $true }
$num0 = @{ precision = 0 }
$money0 = @{ prefix = '$'; precision = 0 }
$relative = @{ outputRelative = $true }

# --- new modules -------------------------------------------------------------
$segment = Ensure-Module 'Segment' 'Segment' @(
    (F 'name' 'String' 'Segment name' @{} $true),
    (F 'list_type' 'Select' 'List type' @{ displayType = 'badge'; options = (Opts @('Active', 'Static') @{ Active = 'Active (updates automatically)'; Static = 'Static (fixed snapshot)' }) } $true 'Active'),
    (F 'filter' 'String' 'Filter' @{ multiLine = $true }),
    (F 'category' 'Select' 'Folder' @{ options = (Opts @('Marketing', 'Sales', 'Customers', 'Re-engagement', 'Other')) }),
    (F 'description' 'String' 'Description' @{ multiLine = $true }),
    (F 'contact_count' 'Number' 'Contacts' $num0),
    (F 'last_refreshed_at' 'DateTime' 'Last refreshed' $relative),
    (F 'owner' 'User' 'Owner' $userOpts)
)

[void](Ensure-Module 'SegmentMember' 'Segment member' @(
    (F 'segment' 'Record' 'Segment' (RecordOpts $segment.moduleID 'name' @('name')) $true),
    (F 'contact' 'Record' 'Contact' (RecordOpts $contact.moduleID 'full_name' @('full_name', 'email')) $true),
    (F 'source' 'Select' 'Added by' @{ options = (Opts @('Filter snapshot', 'Manual', 'Import')) } $false 'Manual'),
    (F 'added_at' 'DateTime' 'Added at')
))

$folder = Ensure-Module 'EmailFolder' 'Email folder' @(
    (F 'name' 'String' 'Folder name' @{} $true),
    (F 'description' 'String' 'Description' @{ multiLine = $true }),
    (F 'owner' 'User' 'Owner' $userOpts)
)

$campaign = Ensure-Module 'Campaign' 'Campaign' @(
    (F 'name' 'String' 'Campaign name' @{} $true),
    (F 'status' 'Select' 'Status' @{ displayType = 'badge'; options = (Opts @('Planning', 'Active', 'Paused', 'Completed')) } $false 'Planning'),
    (F 'owner' 'User' 'Campaign owner' $userOpts),
    (F 'start_date' 'DateTime' 'Start date' @{ onlyDate = $true }),
    (F 'end_date' 'DateTime' 'End date' @{ onlyDate = $true }),
    (F 'budget' 'Number' 'Budget' @{ precision = 2 }),
    (F 'audience' 'Record' 'Audience (list)' (RecordOpts $segment.moduleID 'name' @('name'))),
    (F 'channels' 'Select' 'Channels' @{ options = (Opts @('Email', 'Social media', 'Google Ads', 'Blog', 'Landing page', 'Events')) } $false $null $true),
    (F 'about' 'String' 'What is your campaign about?' @{ multiLine = $true }),
    (F 'key_message_1' 'String' 'What do you want your audience to know? (1)'),
    (F 'key_message_2' 'String' 'What do you want your audience to know? (2)'),
    (F 'key_message_3' 'String' 'What do you want your audience to know? (3)'),
    (F 'keywords' 'String' 'Keywords'),
    (F 'call_to_action' 'String' 'What do you want your audience to do?'),
    (F 'writing_style' 'Select' 'Writing style' @{ options = (Opts @('Professional', 'Friendly', 'Helpful', 'Persuasive', 'Informative', 'Creative', 'Humorous')) } $false $null $true),
    (F 'generated_content' 'String' 'Generated content' @{ multiLine = $true; useRichTextEditor = $true }),
    (F 'notes' 'String' 'Notes' @{ multiLine = $true })
)

# only administrators can read this module (1050_access_control.yaml)
[void](Ensure-Module 'AiSettings' 'AI settings' @(
    (F 'name' 'String' 'Name' @{} $false 'Claude API'),
    (F 'anthropic_api_key' 'String' 'Anthropic API key'),
    (F 'model' 'Select' 'Model' @{ options = (Opts @('claude-opus-5-5', 'claude-sonnet-5-5') @{ 'claude-opus-5-5' = 'Claude Opus 5.5 (best quality)'; 'claude-sonnet-5-5' = 'Claude Sonnet 5.5 (about half the cost)' }) } $false 'claude-opus-5-5'),
    (F 'effort' 'Select' 'Effort' @{ options = (Opts @('low', 'medium', 'high') @{ low = 'Low (fastest, cheapest)'; medium = 'Medium (recommended)'; high = 'High (most thorough)' }) } $false 'medium')
))

# --- existing modules --------------------------------------------------------
$lifecycleTexts = @{ MQL = 'Marketing qualified lead'; SQL = 'Sales qualified lead' }
Update-Module 'Segment' @(
    (F 'match_lifecycle' 'Select' 'Lifecycle stage is any of' @{ options = (Opts @('Subscriber', 'Lead', 'MQL', 'SQL', 'Opportunity', 'Customer', 'Evangelist', 'Other') $lifecycleTexts) } $false $null $true),
    (F 'match_lead_source' 'Select' 'Lead source is any of' @{ options = (Opts @('Organic search', 'Paid search', 'Organic social', 'Paid social', 'Email marketing', 'Referral', 'Direct traffic', 'Event', 'Offline', 'Other')) } $false $null $true),
    (F 'match_status' 'Select' 'Lead status is any of' @{ options = (Opts @('New', 'Open', 'In progress', 'Attempted to contact', 'Connected', 'Unqualified', 'Bad timing')) } $false $null $true),
    (F 'match_owner' 'User' 'Contact owner is any of' @{} $false $null $true),
    (F 'match_country' 'String' 'Country is'),
    (F 'match_tag' 'String' 'Has tag'),
    (F 'match_engagement' 'Select' 'Email engagement' @{ options = (Opts @('Opened recently', 'Clicked recently', 'Never opened', 'Not emailed') @{ 'Opened recently' = 'Opened an email in the last 30 days'; 'Clicked recently' = 'Clicked an email in the last 30 days'; 'Never opened' = 'Has never opened a marketing email'; 'Not emailed' = 'Has never been sent a marketing email' }) }),
    (F 'match_deals' 'Select' 'Deals' @{ options = (Opts @('Open deal', 'Won deal', 'No deals') @{ 'Open deal' = 'Has an open deal'; 'Won deal' = 'Has won a deal (customer)'; 'No deals' = 'Has no deals' }) }),
    (F 'use_advanced_filter' 'Bool' 'Write the filter myself (advanced)')
) {
    param($mod)
    $filter = $mod.fields | Where-Object { $_.name -eq 'filter' }
    $filter.label = 'Filter (written automatically from the choices above)'
}

Update-Module 'Company' @(
    (F 'domain' 'String' 'Email domain')
)

Update-Module 'Contact' @(
    (F 'email_domain' 'String' 'Email domain'),
    (F 'city' 'String' 'City'),
    (F 'country' 'String' 'Country'),
    (F 'deals_count' 'Number' 'Deals' $num0),
    (F 'open_deals_count' 'Number' 'Open deals' $num0),
    (F 'won_deals_count' 'Number' 'Won deals' $num0),
    (F 'open_pipeline' 'Number' 'Open pipeline value' $money0),
    (F 'won_revenue' 'Number' 'Won revenue' $money0),
    (F 'emails_sent_count' 'Number' 'Marketing emails sent' $num0),
    (F 'emails_opened_count' 'Number' 'Marketing emails opened' $num0),
    (F 'emails_clicked_count' 'Number' 'Marketing emails clicked' $num0),
    (F 'last_email_opened_at' 'DateTime' 'Last email opened' $relative),
    (F 'last_email_clicked_at' 'DateTime' 'Last email clicked' $relative)
)

Update-Module 'EmailTemplate' @(
    (F 'preview_url' 'String' 'Preview URL'),
    (F 'folder' 'Record' 'Folder' (RecordOpts $folder.moduleID 'name' @('name')))
) {
    param($mod)
    $html = $mod.fields | Where-Object { $_.name -eq 'body_html' }
    $html.label = 'HTML code (paste your email HTML here)'
    $html.options | Add-Member -Force NoteProperty multiLine $true
    $html.options | Add-Member -Force NoteProperty useRichTextEditor $false
    $html.options | Add-Member -Force NoteProperty sanitizeXSS $false
}

Update-Module 'EmailCampaign' @(
    (F 'segment' 'Record' 'Audience segment' (RecordOpts $segment.moduleID 'name' @('name'))),
    (F 'folder' 'Record' 'Folder' (RecordOpts $folder.moduleID 'name' @('name'))),
    (F 'campaign' 'Record' 'Campaign' (RecordOpts $campaign.moduleID 'name' @('name')))
) {
    param($mod)
    # an email, which can belong to a campaign
    $mod.name = 'Email'
    ($mod.fields | Where-Object { $_.name -eq 'name' }).label = 'Email name'
    $status = $mod.fields | Where-Object { $_.name -eq 'status' }
    if (-not ($status.options.options | Where-Object { $_.value -eq 'Archived' })) {
        $status.options.options = @($status.options.options) + [pscustomobject]@{ value = 'Archived'; text = 'Archived' }
    }
    $aq = $mod.fields | Where-Object { $_.name -eq 'audience_query' }
    $aq.label = 'Extra audience filter (advanced, optional)'
    $aq.defaultValue = @()
}

Update-Module 'AutomationRun' @(
    (F 'segment' 'Record' 'Segment' (RecordOpts $segment.moduleID 'name' @('name')))
)

Write-Host 'Module changes applied.'
