$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

function Read-All {
    param([string]$Path)
    return Get-Content -Path (Join-Path $Root $Path) -Raw
}

function Assert-Match {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $text = Read-All $Path
    if ($text -notmatch $Pattern) { throw $Message }
}

function Assert-NotMatch {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $text = Read-All $Path
    if ($text -match $Pattern) { throw $Message }
}

function Assert-Exists {
    param([string]$Path, [string]$Message)
    if (-not (Test-Path (Join-Path $Root $Path))) { throw $Message }
}

Write-Host '[xml-svg] Checking SVG library boundaries...' -ForegroundColor Yellow
Assert-NotMatch 'src\user\grithl\lib\svg.ghl' 'use\s+svg2\b' 'svg.ghl must not import svg2.ghl.'
Assert-NotMatch 'src\user\grithl\apps\settings.ghl' 'use\s+svg2\b' 'Settings must not import the heavy svg2 renderer.'
Assert-Match 'src\user\grithl\lib\svg2.ghl' 'use\s+svg2\.style' 'svg2.ghl must remain a split facade over concern libraries.'
Assert-Match 'src\user\grithl\lib\svg2\core.ghl' 'svg_style_buf:\s+256' 'svg2 core must keep style parsing in a dedicated scratch buffer.'
Assert-Match 'src\user\grithl\lib\svg2\core.ghl' 'svg_points_buf:\s+256' 'svg2 core must keep point parsing in a dedicated scratch buffer.'
Assert-Match 'src\user\grithl\lib\svg2\core.ghl' 'svg_path_buf:\s+512' 'svg2 core must keep path parsing in a dedicated scratch buffer.'
Assert-Match 'src\user\grithl\lib\svg2\path.ghl' 'fn svg_path_run_cmd' 'svg_draw_path must dispatch through per-command helpers.'
Assert-Match 'src\user\grithl\lib\svg2\path.ghl' 'fn svg_path_arc_abs' 'SVG path arc handling must stay isolated in a helper.'
Assert-Match 'src\user\grithl\lib\svg2\path.ghl' 'fn svg_path_cubic_abs' 'SVG path cubic handling must stay isolated in a helper.'

Write-Host '[xml-svg] Checking SVG docs and fixtures...' -ForegroundColor Yellow
Assert-Match 'docs\grithl-svg.md' 'Keep `svg\.ghl` small' 'SVG docs must preserve svg.ghl ownership guidance.'
Assert-Match 'docs\grithl-svg.md' 'svg2\.ghl` can[\s\r\n]+grow because it is opt-in' 'SVG docs must say svg2.ghl is the opt-in growth point.'
Assert-Match 'docs\grithl-svg.md' 'Hard limits' 'SVG docs must publish hard input/path limits.'
Assert-Match 'docs\grithl-svg.md' 'Support Matrix' 'SVG docs must keep the support matrix.'
Assert-Match 'tests\ghl\svg_render_smoke.ghl' 'svg_render\(&smoke_svg' 'SVG smoke fixture must call svg_render.'
Assert-Match 'tests\ghl\svg_render_smoke.ghl' '\[ghll\] svg2 render pass' 'SVG smoke fixture must emit a runtime pass marker.'
Assert-Exists 'tests\svg\svg_render_smoke.baseline.txt' 'SVG visual regression baseline descriptor is missing.'
Assert-Match 'tests\svg\svg_render_smoke.baseline.txt' 'expected-marker: \[ghll\] svg2 render pass' 'SVG baseline must name the runtime pass marker.'

Write-Host '[xml-svg] Checking XML syscall table stability...' -ForegroundColor Yellow
$syscall = Read-All 'src\kernel\proc\syscall_support.inc'
$xmlEntries = [regex]::Matches($syscall, 'SYSCALL_ENTRY syscall_entry\.sc_(xml|draw|fill|blend)_[^,\r\n]+')
$names = @($xmlEntries | ForEach-Object { $_.Value -replace '^SYSCALL_ENTRY syscall_entry\.', '' })
$expected = @(
    'sc_xml_parse','sc_xml_root','sc_xml_tag','sc_xml_tag_name',
    'sc_xml_first_child','sc_xml_next_sibling','sc_xml_parent',
    'sc_xml_attr','sc_xml_text','sc_xml_free','sc_draw_line',
    'sc_fill_circle','sc_fill_triangle','sc_xml_last_error',
    'sc_xml_node_count','sc_blend_pixel','sc_blend_span',
    'sc_xml_text_runs','sc_xml_text_run','sc_xml_namespace',
    'sc_xml_node_namespace','sc_xml_entity_value'
)
for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($names[$i] -ne $expected[$i]) {
        throw "XML syscall order drifted at slot $($i + 30): expected $($expected[$i]), saw $($names[$i])"
    }
}

Write-Host '[xml-svg] Checking XML docs and fixtures...' -ForegroundColor Yellow
Assert-Match 'src\user\grithl\lib\xml.ghl' 'const XML_MAX_NODES\s+=\s+8192' 'GritHL XML capacities must mirror parser arena limits.'
Assert-Match 'src\user\grithl\lib\xml.ghl' 'fn xml_next_child' 'GritHL XML must expose a safe child walking helper.'
Assert-Match 'src\user\grithl\lib\xml.ghl' 'fn xml_same_tag' 'GritHL XML must expose tag-id matching without scratch copies.'
Assert-Match 'src\user\grithl\lib\xml.ghl' 'fn xml_text_run' 'GritHL XML must expose mixed-content text run traversal.'
Assert-Match 'src\user\grithl\lib\xml.ghl' 'fn xml_namespace' 'GritHL XML must expose namespace URI lookup.'
Assert-Match 'src\user\grithl\lib\xml.ghl' 'fn xml_entity_value' 'GritHL XML must expose custom entity lookup.'
Assert-Match 'docs\grithl-xml.md' 'XML_MAX_NODES' 'XML docs must surface parser capacities.'
Assert-Match 'docs\grithl-xml.md' 'Single live document' 'XML docs must document single live document behavior.'
Assert-Match 'docs\grithl-xml.md' 'Custom internal entities' 'XML docs must document internal-DTD entity support.'
Assert-Match 'docs\grithl-xml.md' 'Mixed text runs' 'XML docs must document mixed-content text traversal.'
Assert-Match 'tests\ghl\xml_diag_smoke.ghl' '\[ghll\] xml diag pass' 'XML diagnostic smoke must emit a runtime pass marker.'
Assert-Match 'tests\ghl\xml_diag_smoke.ghl' 'XML_ERR_MISMATCH' 'XML diagnostic smoke must assert xml_last_error.'
Assert-Match 'tests\ghl\xml_diag_smoke.ghl' 'single_a' 'XML diagnostic smoke must guard single-live-document replacement.'
Assert-Match 'tests\ghl\xml_diag_smoke.ghl' 'mixed_xml' 'XML diagnostic smoke must cover mixed-content text runs.'
Assert-Match 'tests\ghl\xml_diag_smoke.ghl' 'entity_xml' 'XML diagnostic smoke must cover custom internal entities.'
Assert-Exists 'tests\xml\05_namespace_literal.xml' 'Namespace literal XML fixture is missing.'
Assert-Exists 'tests\xml\bad_unterminated_comment.xml' 'Malformed XML comment fixture is missing.'
Assert-Exists 'tests\xml\bad_mismatch_deep.xml' 'Malformed XML mismatch fixture is missing.'

Write-Host '[xml-svg] PASS' -ForegroundColor Green
