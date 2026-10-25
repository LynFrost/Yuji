$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$builder = Join-Path $root 'Build-CodexChatIndex.ps1'

Describe 'V0.35 explicit session inheritance and one-button controls' {
    BeforeAll {
        $script:tempRoot = Join-Path $env:TEMP ('Yuji035-' + [guid]::NewGuid().ToString('N'))
        $script:codexHome = Join-Path $tempRoot 'codex'
        $script:codexData = Join-Path $tempRoot 'codex-data'
        $script:cwd = Join-Path $tempRoot 'workspace'
        $codexDir = Join-Path $codexHome 'sessions\2026\10\25'
        New-Item -ItemType Directory -Force $codexDir, $cwd | Out-Null

        $script:rootId = '35350000-0000-4000-8000-000000000001'
        $script:childId = '35350000-0000-4000-8000-000000000002'
        $script:grandId = '35350000-0000-4000-8000-000000000003'
        $script:siblingId = '35350000-0000-4000-8000-000000000004'
        $script:orphanId = '35350000-0000-4000-8000-000000000005'
        $script:missingId = '35350000-0000-4000-8000-000000000099'
        $script:cycleA = '35350000-0000-4000-8000-000000000006'
        $script:cycleB = '35350000-0000-4000-8000-000000000007'
        function Write-CodexFixture {
            param([string]$SessionId, [string]$ParentId, [string[]]$Texts)
            $meta = [ordered]@{
                timestamp = '2026-10-25T08:00:00Z'
                type = 'session_meta'
                payload = [ordered]@{
                    id = $SessionId
                    forked_from_id = $ParentId
                    timestamp = '2026-10-25T08:00:00Z'
                    cwd = $script:cwd
                    source = 'cli'
                }
            }
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add(($meta | ConvertTo-Json -Depth 30 -Compress))
            foreach ($text in $Texts) {
                $lines.Add(([ordered]@{
                    timestamp = '2026-10-25T08:00:01Z'
                    type = 'event_msg'
                    payload = [ordered]@{ type = 'user_message'; message = $text }
                } | ConvertTo-Json -Depth 30 -Compress))
            }
            $path = Join-Path $codexDir ('rollout-2026-10-25T08-00-00-' + $SessionId + '.jsonl')
            Set-Content -LiteralPath $path -Value $lines.ToArray() -Encoding UTF8
        }
        Write-CodexFixture $rootId '' @('Root only')
        Write-CodexFixture $childId $rootId @('Child earlier own content', 'Child later own content')
        Write-CodexFixture $grandId $childId @('Grandchild only')
        Write-CodexFixture $siblingId $rootId @('Sibling only')
        Write-CodexFixture $orphanId $missingId @('Orphan only')
        Write-CodexFixture $cycleA $cycleB @('Cycle A')
        Write-CodexFixture $cycleB $cycleA @('Cycle B')

        $codexOutput = Join-Path $tempRoot 'CodexChatIndex.html'
        & $builder -CodexHome $codexHome -OutputPath $codexOutput -DataRoot $codexData -RefreshMode Full | Out-Null
        $script:html = Get-Content -LiteralPath $codexOutput -Raw
        $codexIndex = Get-Content -LiteralPath (Join-Path $codexData 'CodexChatIndex.sources\local-codex\CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $script:sessions = @($codexIndex.workspaces | ForEach-Object { @($_.sessions) })

        $script:claudeHome = Join-Path $tempRoot 'claude'
        $claudeDir = Join-Path $claudeHome 'projects\fixture'
        New-Item -ItemType Directory -Force $claudeDir | Out-Null
        $script:claudeRootId = '35350000-0000-4000-8000-000000000011'
        $script:claudeChildId = '35350000-0000-4000-8000-000000000012'
        function Write-ClaudeFixture {
            param([string]$SessionId, [string]$ParentId)
            $entry = [ordered]@{
                type = 'user'
                sessionId = $SessionId
                timestamp = '2026-10-25T09:00:00Z'
                cwd = $script:cwd
                parentUuid = 'only-a-message-link'
                message = [ordered]@{ role = 'user'; content = ('Claude ' + $SessionId) }
            }
            if ($ParentId) { $entry.forkedFrom = [ordered]@{ sessionId = $ParentId; messageId = 'message-123' } }
            $json = $entry | ConvertTo-Json -Depth 30 -Compress
            Set-Content -LiteralPath (Join-Path $claudeDir ($SessionId + '.jsonl')) -Value $json -Encoding UTF8
        }
        Write-ClaudeFixture $claudeRootId ''
        Write-ClaudeFixture $claudeChildId $claudeRootId
        $claudeOutput = Join-Path $tempRoot 'claude-view.html'
        $claudeData = Join-Path $tempRoot 'claude-data'
        & $builder -ClaudeHome $claudeHome -SourceType local-claude -OutputPath $claudeOutput -DataRoot $claudeData -RefreshMode Full | Out-Null
        $claudeIndex = Get-Content -LiteralPath (Join-Path $claudeData 'CodexChatIndex.sources\local-claude\CodexChatIndex.data.json') -Raw | ConvertFrom-Json -Depth 100
        $script:claudeSessions = @($claudeIndex.workspaces | ForEach-Object { @($_.sessions) })
    }

    It 'keeps Codex root child grandchild and sibling ancestry precise' {
        $child = @($sessions | Where-Object id -eq $childId)[0]
        $grand = @($sessions | Where-Object id -eq $grandId)[0]
        $sibling = @($sessions | Where-Object id -eq $siblingId)[0]
        $child.parentSessionId | Should Be $rootId
        $child.relationStatus | Should Be 'confirmed'
        $grand.parentSessionId | Should Be $childId
        $grand.relationStatus | Should Be 'confirmed'
        $sibling.parentSessionId | Should Be $rootId
        $sibling.relationStatus | Should Be 'confirmed'
    }

    It 'shows orphan sessions and marks broken or cyclic ancestry' {
        $orphan = @($sessions | Where-Object id -eq $orphanId)[0]
        $a = @($sessions | Where-Object id -eq $cycleA)[0]
        $b = @($sessions | Where-Object id -eq $cycleB)[0]
        $orphan.parentSessionId | Should Be $missingId
        $orphan.relationStatus | Should Be 'missing'
        $a.relationStatus | Should Be 'invalid'
        $b.relationStatus | Should Be 'invalid'
    }

    It 'does not truncate the childs own early messages or append parent and sibling messages' {
        $child = @($sessions | Where-Object id -eq $childId)[0]
        $href = [IO.Path]::GetFullPath((Join-Path $tempRoot ([string]$child.detailHref)))
        $detail = Get-Content -LiteralPath $href -Raw | ConvertFrom-Json -Depth 100
        $messages = @($detail.events | Where-Object kind -eq 'user' | ForEach-Object rawText)
        ($messages -join '|') | Should Match 'Child earlier own content'
        ($messages -join '|') | Should Match 'Child later own content'
        ($messages -join '|') | Should Not Match 'Root only|Sibling only'
    }

    It 'uses Claude session-level fork metadata and ignores message parentUuid' {
        $root = @($claudeSessions | Where-Object id -eq $claudeRootId)[0]
        $child = @($claudeSessions | Where-Object id -eq $claudeChildId)[0]
        $root | Should Not BeNullOrEmpty
        $child | Should Not BeNullOrEmpty
        $child.parentSessionId | Should Be $claudeRootId
        $child.relationStatus | Should Be 'confirmed'
        [string]$root.parentSessionId | Should Be ''
    }

    It 'renders exactly one independent button per mode and preserves the search field button' {
        ([regex]::Matches($html, '<button type="button" data-search-scope=')).Count | Should Be 1
        ([regex]::Matches($html, '<button type="button" data-view-mode=')).Count | Should Be 1
        ([regex]::Matches($html, '<button type="button" data-search-field=')).Count | Should Be 1
        $html | Should Match 'function getInheritanceDisplayRows\(group\)'
        $html | Should Match "viewerSearchScope = previousScope === 'current' \? 'all' : 'current'"
        $html | Should Match "viewerViewMode = previousMode === 'questions' \? 'all' : 'questions'"
    }

    It 'renders one-line session descriptions and branch-aware inheritance connectors' {
        $templatePath = Join-Path $root 'templates\CodexChatIndex.template.html'
        $template = Get-Content -LiteralPath $templatePath -Raw
        $template | Should Match '\.session-description \{[\s\S]*?white-space: nowrap'
        $template | Should Match '\.session-description \{[\s\S]*?text-overflow: ellipsis'
        $template | Should Match 'const description = String\(session\.summary \|\| session\.title \|\|'
        $template | Should Match 'function buildInheritanceConnectorSvg\(row\)'
        $template | Should Match 'ancestorHasNext'
        $template | Should Match 'placeholder\.innerHTML = buildInheritanceConnectorSvg\(row\)'
        $template | Should Not Match '<span class="session-meta">'

        $node = @'
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
const match = html.match(/function getInheritanceRegistry\(sessions\) \{[\s\S]*?(?=    function hasMultipleSessionBranches\(group\))/);
if (!match) throw new Error("inheritance display helpers not found");
function compareDate(a, b) { return Date.parse(a || "") - Date.parse(b || ""); }
function compareText(a, b) { return String(a || "").localeCompare(String(b || "")); }
var APP = { workspaces: [] };
const sessions = [
  { id: "root", title: "Root title", summary: "Root own question", parentSessionId: "", relationStatus: "", createdAt: "2026-10-25T08:00:00Z" },
  { id: "child", title: "Child title", summary: "Child own question", parentSessionId: "root", relationStatus: "confirmed", createdAt: "2026-10-25T08:01:00Z" },
  { id: "grand", title: "Grand title", summary: "Grand own question", parentSessionId: "child", relationStatus: "confirmed", createdAt: "2026-10-25T08:02:00Z" },
  { id: "sibling", title: "Sibling title", summary: "Sibling own question", parentSessionId: "root", relationStatus: "confirmed", createdAt: "2026-10-25T08:03:00Z" }
];
APP = { workspaces: [{ sessions }] };
eval(match[0]);
const group = { isInheritanceGroup: true, sessions, inheritance: getInheritanceRegistry(sessions) };
const rows = getInheritanceDisplayRows(group);
const byId = Object.fromEntries(rows.filter(row => row.session).map(row => [row.id, row]));
const rootConnector = buildInheritanceConnectorSvg(byId.root);
const childConnector = buildInheritanceConnectorSvg(byId.child);
const grandConnector = buildInheritanceConnectorSvg(byId.grand);
console.log(JSON.stringify({
  order: rows.map(row => row.id),
  childDepth: byId.child.depth,
  childIsLast: byId.child.isLastChild,
  grandDepth: byId.grand.depth,
  grandAncestorHasNext: byId.grand.ancestorHasNext,
  siblingIsLast: byId.sibling.isLastChild,
  rootChildStem: rootConnector.includes('<line x1="7" y1="50" x2="7" y2="100"></line>'),
  childChildStem: childConnector.includes('<line x1="21" y1="50" x2="21" y2="100"></line>'),
  ancestorLine: grandConnector.includes('<line x1="7" y1="0" x2="7" y2="100"></line>'),
  currentLastLine: grandConnector.includes('<line x1="21" y1="0" x2="21" y2="50"></line>')
}));
'@
        $result = node -e $node $templatePath | ConvertFrom-Json -Depth 10
        ($result.order -join ',') | Should Be 'root,child,grand,sibling'
        $result.childDepth | Should Be 1
        $result.childIsLast | Should Be $false
        $result.grandDepth | Should Be 2
        $result.grandAncestorHasNext.Count | Should Be 1
        $result.grandAncestorHasNext[0] | Should Be $true
        $result.siblingIsLast | Should Be $true
        $result.rootChildStem | Should Be $true
        $result.childChildStem | Should Be $true
        $result.ancestorLine | Should Be $true
        $result.currentLastLine | Should Be $true
    }

    AfterAll {
        Remove-Item -LiteralPath $script:tempRoot -Force -Recurse -ErrorAction SilentlyContinue
    }
}
