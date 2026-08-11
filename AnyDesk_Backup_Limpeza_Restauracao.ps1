#requires -RunAsAdministrator
<#
.SYNOPSIS
    Limpeza segura do AnyDesk preservando automaticamente o ID/Alias.

.DESCRIPTION
    - Encerra processos e serviços do AnyDesk.
    - Localiza service.conf em instalações padrão e customizadas.
    - Faz backup completo da pasta de configuração.
    - Valida o backup antes de continuar.
    - Remove os dados de configuração/cache do AnyDesk.
    - Restaura SOMENTE o service.conf para preservar ID/Alias.
    - Reinicia o serviço/processo quando possível.

IMPORTANTE:
    Este script é para manutenção/reparo de instalação.
    Ele não remove nem contorna limitações, licenciamento ou tempos de espera
    aplicados pelo serviço AnyDesk.

    Como apenas service.conf é restaurado automaticamente, outras configurações
    locais (incluindo preferências e possivelmente Acesso Não Supervisionado)
    podem precisar ser configuradas novamente.

    Um backup COMPLETO é mantido em C:\AnyDesk_Backup\<data-hora>\
#>

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[AVISO] $Message" -ForegroundColor Yellow
}

function Stop-AnyDesk {
    Write-Step "Encerrando AnyDesk"

    Get-Process -Name "AnyDesk" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $services = Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "*AnyDesk*" -or
            $_.DisplayName -like "*AnyDesk*"
        }

    foreach ($svc in $services) {
        try {
            if ($svc.Status -ne "Stopped") {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                Write-OK "Servico parado: $($svc.Name)"
            }
        }
        catch {
            Write-Warn "Nao foi possivel parar o servico $($svc.Name): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

# --------------------------------------------------------------------
# 1. Verificar privilégios
# --------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Execute este script como ADMINISTRADOR." -ForegroundColor Red
    exit 1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ANYDESK - BACKUP DO ID + LIMPEZA + RESTAURACAO AUTOMATICA" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Stop-AnyDesk

# --------------------------------------------------------------------
# 2. Localizar service.conf
# --------------------------------------------------------------------
Write-Step "Localizando o service.conf que contem o ID/Alias"

$roots = @(
    "$env:ProgramData\AnyDesk",
    "$env:APPDATA\AnyDesk"
) | Where-Object { $_ -and (Test-Path $_) }

$serviceFiles = @()

foreach ($root in $roots) {
    try {
        $serviceFiles += Get-ChildItem -Path $root -Filter "service.conf" `
            -File -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

$serviceFiles = @($serviceFiles | Sort-Object FullName -Unique)

if ($serviceFiles.Count -eq 0) {
    Write-Host "`nERRO: Nenhum service.conf foi encontrado." -ForegroundColor Red
    Write-Host "A limpeza foi CANCELADA para evitar a perda do ID." -ForegroundColor Red
    exit 2
}

Write-Host "`nArquivos encontrados:" -ForegroundColor White
for ($i = 0; $i -lt $serviceFiles.Count; $i++) {
    Write-Host "[$i] $($serviceFiles[$i].FullName)"
}

# Em instalações normais existe um único service.conf.
# Se houver vários clientes AnyDesk/custom clients, todos serão preservados.
Write-OK "$($serviceFiles.Count) arquivo(s) service.conf encontrado(s)"

# --------------------------------------------------------------------
# 3. Criar backup
# --------------------------------------------------------------------
Write-Step "Criando backup"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = "C:\AnyDesk_Backup\$timestamp"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$manifest = @()

foreach ($serviceFile in $serviceFiles) {

    $configFolder = $serviceFile.Directory.FullName

    # Descobrir se veio de ProgramData ou AppData para manter estrutura
    if ($configFolder.StartsWith($env:ProgramData, [System.StringComparison]::OrdinalIgnoreCase)) {
        $baseRoot = $env:ProgramData
        $baseName = "ProgramData"
    }
    elseif ($configFolder.StartsWith($env:APPDATA, [System.StringComparison]::OrdinalIgnoreCase)) {
        $baseRoot = $env:APPDATA
        $baseName = "AppData"
    }
    else {
        Write-Warn "Caminho inesperado: $configFolder"
        continue
    }

    $relativeConfig = $configFolder.Substring($baseRoot.Length).TrimStart('\')
    $backupFolder = Join-Path $backupRoot "$baseName\$relativeConfig"

    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

    # Backup completo da pasta em que o service.conf está
    Copy-Item -Path (Join-Path $configFolder "*") `
        -Destination $backupFolder `
        -Recurse -Force -ErrorAction Stop

    $backupService = Join-Path $backupFolder "service.conf"

    if (-not (Test-Path $backupService)) {
        Write-Host "ERRO: O backup de service.conf falhou." -ForegroundColor Red
        Write-Host "Limpeza CANCELADA." -ForegroundColor Red
        exit 3
    }

    $originalHash = (Get-FileHash $serviceFile.FullName -Algorithm SHA256).Hash
    $backupHash   = (Get-FileHash $backupService -Algorithm SHA256).Hash

    if ($originalHash -ne $backupHash) {
        Write-Host "ERRO: O hash do backup nao corresponde ao original." -ForegroundColor Red
        Write-Host "Limpeza CANCELADA." -ForegroundColor Red
        exit 4
    }

    $manifest += [PSCustomObject]@{
        OriginalServiceConf = $serviceFile.FullName
        OriginalConfigDir   = $configFolder
        BackupServiceConf   = $backupService
        BackupConfigDir     = $backupFolder
        SHA256               = $backupHash
    }

    Write-OK "Backup validado: $backupService"
}

$manifestPath = Join-Path $backupRoot "manifest.csv"
$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

# Backup extra do manifesto em TXT para leitura simples
$manifest | Format-List | Out-File (Join-Path $backupRoot "manifest.txt") -Encoding UTF8

Write-OK "Backup completo salvo em: $backupRoot"

# --------------------------------------------------------------------
# 4. Limpar configurações/cache
# --------------------------------------------------------------------
Write-Step "Limpando dados locais do AnyDesk"

# Remover somente diretórios AnyDesk que tiveram service.conf detectado,
# evitando apagar indiscriminadamente arquivos não relacionados.
$configDirs = @($manifest.OriginalConfigDir | Sort-Object -Unique)

foreach ($dir in $configDirs) {
    if (Test-Path $dir) {
        Write-Host "Removendo configuracao: $dir"
        Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
    }
}

# Limpar temporários relacionados ao AnyDesk
$tempCandidates = @(
    "$env:TEMP\AnyDesk",
    "$env:LOCALAPPDATA\AnyDesk"
)

foreach ($path in $tempCandidates) {
    if ($path -and (Test-Path $path)) {
        Write-Host "Removendo cache/temporario: $path"
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*AnyDesk*" } |
    ForEach-Object {
        try {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "Removido temporario: $($_.FullName)"
        }
        catch {}
    }

Write-OK "Limpeza concluida"

# --------------------------------------------------------------------
# 5. Restaurar automaticamente SOMENTE service.conf
# --------------------------------------------------------------------
Write-Step "Restaurando ID/Alias"

foreach ($item in $manifest) {

    $destinationDir = Split-Path $item.OriginalServiceConf -Parent
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

    Copy-Item -Path $item.BackupServiceConf `
        -Destination $item.OriginalServiceConf `
        -Force -ErrorAction Stop

    if (-not (Test-Path $item.OriginalServiceConf)) {
        Write-Host "ERRO: Nao foi possivel restaurar $($item.OriginalServiceConf)" -ForegroundColor Red
        exit 5
    }

    $restoredHash = (Get-FileHash $item.OriginalServiceConf -Algorithm SHA256).Hash

    if ($restoredHash -ne $item.SHA256) {
        Write-Host "ERRO: O service.conf restaurado nao corresponde ao backup." -ForegroundColor Red
        exit 6
    }

    Write-OK "ID/Alias restaurado em: $($item.OriginalServiceConf)"
}

# --------------------------------------------------------------------
# 6. Iniciar serviço AnyDesk
# --------------------------------------------------------------------
Write-Step "Iniciando AnyDesk"

$services = Get-Service -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "*AnyDesk*" -or
        $_.DisplayName -like "*AnyDesk*"
    }

$startedService = $false

foreach ($svc in $services) {
    try {
        Start-Service -Name $svc.Name -ErrorAction Stop
        Write-OK "Servico iniciado: $($svc.Name)"
        $startedService = $true
    }
    catch {
        Write-Warn "Nao foi possivel iniciar o servico $($svc.Name): $($_.Exception.Message)"
    }
}

# Se não houver serviço ou ele não subir, tentar localizar o executável instalado
if (-not $startedService) {

    $exeCandidates = @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($exeCandidates.Count -gt 0) {
        try {
            Start-Process $exeCandidates[0]
            Write-OK "AnyDesk iniciado: $($exeCandidates[0])"
        }
        catch {
            Write-Warn "Abra o AnyDesk manualmente."
        }
    }
    else {
        Write-Warn "Executavel instalado nao localizado. Abra/reinstale o AnyDesk manualmente."
    }
}

# --------------------------------------------------------------------
# 7. Resultado
# --------------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " PROCESSO FINALIZADO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Backup de seguranca:" -ForegroundColor White
Write-Host "  $backupRoot" -ForegroundColor Yellow
Write-Host ""
Write-Host "O service.conf original foi restaurado automaticamente." -ForegroundColor Green
Write-Host "Isso preserva o ID/Alias do AnyDesk." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANTE:" -ForegroundColor Yellow
Write-Host "Outras configuracoes locais podem ter sido resetadas." -ForegroundColor Yellow
Write-Host "Se necessario, reconfigure o Acesso Nao Supervisionado no AnyDesk." -ForegroundColor Yellow
Write-Host ""
Write-Host "Nao apague C:\AnyDesk_Backup ate confirmar que o AnyDesk esta funcionando." -ForegroundColor Yellow

Read-Host "`nPressione ENTER para fechar"
