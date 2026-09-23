$ErrorActionPreference = "Stop"

$modelName = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
$expectedSha256 = "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
$url = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/${modelName}?download=true"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modelDirectory = Join-Path $projectRoot "assets\models"
$destination = Join-Path $modelDirectory $modelName
$temporary = "$destination.part"

New-Item -ItemType Directory -Path $modelDirectory -Force | Out-Null

if (Test-Path -LiteralPath $destination) {
    $currentHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -eq $expectedSha256) {
        Write-Host "El modelo oficial ya esta disponible en $destination"
        exit 0
    }
}

Write-Host "Descargando Qwen oficial (aproximadamente 491 MB)..."
& curl.exe -L --fail --retry 3 --output $temporary $url
if ($LASTEXITCODE -ne 0) {
    throw "No se pudo descargar el modelo oficial (curl: $LASTEXITCODE)."
}

$downloadedHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
if ($downloadedHash -ne $expectedSha256) {
    Remove-Item -LiteralPath $temporary -Force
    throw "SHA-256 invalido. Se esperaba $expectedSha256 y se obtuvo $downloadedHash"
}

Move-Item -LiteralPath $temporary -Destination $destination -Force
Write-Host "Modelo verificado y preparado para compilar el APK."
