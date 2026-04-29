<#
.SYNOPSIS
    Enterprise System Inventory Collection Tool
    
.DESCRIPTION
    Collects comprehensive hardware, software, and network information from local or remote computers.
    Supports Active Directory integration, parallel processing, and multiple export formats.
    
.PARAMETER ComputerName
    Target computer(s) to inventory. Default: local machine
    
.PARAMETER OUPath
    Active Directory OU path to query computers from
    Example: "OU=Workstations,OU=IT,DC=company,DC=local"
    
.PARAMETER UseAD
    Query all computers from Active Directory
    
.PARAMETER Credential
    PSCredential object for remote authentication
    
.PARAMETER OutputPath
    Output directory for reports. Default: C:\Scripts\Inventory
    
.PARAMETER ExportFormat
    Export formats: CSV, JSON, HTML, GridView. Default: All
    
.PARAMETER Parallel
    Run inventory collection in parallel (PowerShell 7+ only)
    
.PARAMETER ThrottleLimit
    Maximum concurrent jobs when using -Parallel. Default: 10
#>

[CmdletBinding(DefaultParameterSetName='Direct')]
param(
    [Parameter(ParameterSetName='Direct')]
    [string[]]$ComputerName = $env:COMPUTERNAME,
    
    [Parameter(ParameterSetName='AD', Mandatory=$true)]
    [string]$OUPath,
    
    [Parameter(ParameterSetName='AD')]
    [switch]$UseAD,
    
    [PSCredential]$Credential,
    
    [string]$OutputPath = "C:\Scripts\Inventory",
    
    [ValidateSet('CSV','JSON','HTML','GridView','All')]
    [string[]]$ExportFormat = 'All',
    
    [switch]$Parallel,
    
    [int]$ThrottleLimit = 10
)

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        'Info' = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error' = 'Red'
    }
    
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $colors[$Level]
    
    # Write to separate application log (not the transcript)
    try {
        Add-Content -Path "$script:AppLogFile" -Value $logMessage -ErrorAction SilentlyContinue
    }
    catch {
        # Silently ignore if log file is locked
    }
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level Info
    
    # Check AD module if needed
    if ($UseAD) {
        if (!(Get-Module -ListAvailable ActiveDirectory)) {
            Write-Log "ActiveDirectory module not found!" -Level Error
            Write-Log "Install with: Install-WindowsFeature RSAT-AD-PowerShell" -Level Info
            throw "Missing required module: ActiveDirectory"
        }
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log "ActiveDirectory module loaded" -Level Success
    }
    
    # Check PowerShell version for parallel
    if ($Parallel -and $PSVersionTable.PSVersion.Major -lt 7) {
        Write-Log "Parallel processing requires PowerShell 7+. Falling back to sequential." -Level Warning
        $script:Parallel = $false
    }
}

function Get-TargetComputers {
    Write-Log "Determining target computers..." -Level Info
    
    if ($UseAD) {
        try {
            # 1. ดึงรายชื่อจาก AD โดยหาใน OU ย่อยทั้งหมด (Subtree)
            $adComputers = Get-ADComputer -Filter * -SearchBase $OUPath -SearchScope Subtree -Properties Name | 
                Select-Object -ExpandProperty Name

            # 2. รวมรายชื่อจาก AD เข้ากับชื่อเครื่องตัวเอง ($env:COMPUTERNAME) และกรองชื่อซ้ำออก
            $computers = @($adComputers; $env:COMPUTERNAME) | Select-Object -Unique
            
            Write-Log "Found $($adComputers.Count) from AD and included local machine. Total: $($computers.Count)" -Level Success
            return $computers
        }
        catch {
            Write-Log "Failed to query AD: $($_.Exception.Message)" -Level Error
            throw
        }
    }
    else {
        Write-Log "Target computers: $($ComputerName -join ', ')" -Level Info
        return $ComputerName
    }
}

function Test-ComputerConnectivity {
    param([string]$Computer)
    
    # Test ping
    if (!(Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        return @{
            Success = $false
            Error = "Computer is offline or unreachable"
        }
    }
    
    # Test WinRM for remote computers
    if ($Computer -ne $env:COMPUTERNAME) {
        if (!(Test-WSMan -ComputerName $Computer -ErrorAction SilentlyContinue)) {
            return @{
                Success = $false
                Error = "WinRM is not enabled or accessible"
            }
        }
    }
    
    return @{ Success = $true }
}

function Get-ComputerInventory {
    param(
        [string]$Computer,
        [PSCredential]$Cred
    )
    
    $scriptBlock = {
        try {
            # Gather system information
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
            
            # Network info
            $network = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {$_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*"}
            $adapter = Get-NetAdapter -ErrorAction Stop | 
                Where-Object {$_.Status -eq "Up"} | 
                Select-Object -First 1
            
            # Software count
            $software = @(
                Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue
                Get-ItemProperty HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue
            ) | Where-Object {$_.DisplayName}
            
            # Build result object
            [PSCustomObject]@{
                # Metadata
                ScanDate = Get-Date
                ComputerName = $env:COMPUTERNAME
                Domain = $cs.Domain
                CurrentUser = $env:USERNAME
                Status = "Success"
                
                # Hardware
                Manufacturer = $cs.Manufacturer
                Model = $cs.Model
                SerialNumber = $bios.SerialNumber
                BIOSVersion = $bios.SMBIOSBIOSVersion
                
                # OS
                OperatingSystem = $os.Caption
                OSVersion = $os.Version
                OSArchitecture = $os.OSArchitecture
                InstallDate = $os.InstallDate
                LastBootTime = $os.LastBootUpTime
                
                # CPU
                Processor = $cpu.Name
                CPUCores = $cpu.NumberOfCores
                CPULogicalProcessors = $cpu.NumberOfLogicalProcessors
                
                # Memory
                TotalRAM_GB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                FreeRAM_GB = [math]::Round($os.FreePhysicalMemory / 1MB / 1024, 2)
                
                # Storage
                TotalStorage_GB = [math]::Round(($disks | Measure-Object Size -Sum).Sum / 1GB, 2)
                FreeStorage_GB = [math]::Round(($disks | Measure-Object FreeSpace -Sum).Sum / 1GB, 2)
                DiskDetails = ($disks | ForEach-Object {
                    "$($_.DeviceID) $([math]::Round($_.Size/1GB,2))GB ($([math]::Round($_.FreeSpace/1GB,2))GB free)"
                }) -join "; "
                
                # Network
                IPAddress = ($network.IPAddress -join ", ")
                MACAddress = $adapter.MacAddress
                NetworkAdapter = $adapter.InterfaceDescription
                
                # Software
                InstalledSoftwareCount = ($software | Measure-Object).Count
                
                # Performance
                CPULoad = (Get-CimInstance Win32_Processor).LoadPercentage
                
                ErrorMessage = $null
            }
        }
        catch {
            [PSCustomObject]@{
                ScanDate = Get-Date
                ComputerName = $env:COMPUTERNAME
                Status = "Failed"
                ErrorMessage = $_.Exception.Message
            }
        }
    }
    
    # Execute locally or remotely
    if ($Computer -eq $env:COMPUTERNAME) {
        & $scriptBlock
    }
    else {
        $params = @{
            ComputerName = $Computer
            ScriptBlock = $scriptBlock
            ErrorAction = 'Stop'
        }
        if ($Cred) { $params.Credential = $Cred }
        
        Invoke-Command @params
    }
}

function Export-Results {
    param(
        [array]$Data,
        [string]$BasePath,
        [string[]]$Formats
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    
    if ($Formats -contains 'All') {
        $Formats = @('CSV', 'JSON', 'HTML', 'GridView')
    }
    
    foreach ($format in $Formats) {
        switch ($format) {
            'CSV' {
                $csvPath = "$BasePath\Inventory-$timestamp.csv"
                $Data | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
                Write-Log "CSV exported: $csvPath" -Level Success
            }
            
            'JSON' {
                $jsonPath = "$BasePath\Inventory-$timestamp.json"
                $Data | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8
                Write-Log "JSON exported: $jsonPath" -Level Success
            }
            
            'HTML' {
                $htmlPath = "$BasePath\Inventory-Report-$timestamp.html"
                $html = Get-HTMLReport -Data $Data
                $html | Out-File $htmlPath -Encoding UTF8
                Write-Log "HTML exported: $htmlPath" -Level Success
                
                # Open HTML report
                Start-Process $htmlPath
            }
            
            'GridView' {
                $Data | Out-GridView -Title "System Inventory Results - $(Get-Date)"
                Write-Log "GridView displayed" -Level Success
            }
        }
    }
}

function Get-HTMLReport {
    param([array]$Data)
    
    $successCount = ($Data | Where-Object {$_.Status -eq "Success"}).Count
    $failCount = ($Data | Where-Object {$_.Status -eq "Failed"}).Count
    $totalRAM = ($Data | Where-Object {$_.Status -eq "Success"} | Measure-Object TotalRAM_GB -Sum).Sum
    $totalStorage = ($Data | Where-Object {$_.Status -eq "Success"} | Measure-Object TotalStorage_GB -Sum).Sum
    
    $tableRows = $Data | ForEach-Object {
        $statusColor = if ($_.Status -eq "Success") { "#10b981" } else { "#ef4444" }
        $ramBar = if ($_.TotalRAM_GB) { 
            $ramPercent = [math]::Min(100, ($_.TotalRAM_GB / 64) * 100)
            "<div style='background:#e5e7eb;border-radius:4px;height:20px;'><div style='background:#3b82f6;height:100%;width:$ramPercent%;border-radius:4px;'></div></div>"
        } else { "N/A" }
        
        @"
        <tr>
            <td><strong>$($_.ComputerName)</strong></td>
            <td><span style='color:$statusColor;font-weight:600;'>$($_.Status)</span></td>
            <td>$($_.Manufacturer) $($_.Model)</td>
            <td>$($_.OperatingSystem)</td>
            <td>$($_.Processor -replace 'Intel\(R\) Core\(TM\) ','' -replace 'AMD ','')</td>
            <td>$($_.TotalRAM_GB) GB $ramBar</td>
            <td>$($_.TotalStorage_GB) GB</td>
            <td>$($_.IPAddress)</td>
            <td>$($_.InstalledSoftwareCount)</td>
        </tr>
"@
    } | Out-String
    
    @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Inventory Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            color: #1f2937;
        }
        .container { 
            max-width: 1400px; 
            margin: 0 auto; 
            background: white; 
            border-radius: 16px; 
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #1e3a8a 0%, #3b82f6 100%);
            color: white;
            padding: 40px;
        }
        .header h1 {
            font-size: 32px;
            margin-bottom: 10px;
            display: flex;
            align-items: center;
            gap: 15px;
        }
        .header p { opacity: 0.9; font-size: 16px; }
        
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            padding: 30px 40px;
            background: #f9fafb;
            border-bottom: 1px solid #e5e7eb;
        }
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 12px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }
        .stat-label {
            font-size: 12px;
            color: #6b7280;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        .stat-value {
            font-size: 28px;
            font-weight: 700;
            color: #1f2937;
        }
        .stat-unit {
            font-size: 14px;
            color: #9ca3af;
            margin-left: 5px;
        }
        
        .content { padding: 40px; }
        h2 { 
            color: #1e3a8a; 
            margin-bottom: 20px;
            font-size: 24px;
            border-bottom: 3px solid #3b82f6;
            padding-bottom: 10px;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background: white;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            border-radius: 8px;
            overflow: hidden;
        }
        thead {
            background: linear-gradient(135deg, #1e40af 0%, #3b82f6 100%);
            color: white;
        }
        th {
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        td {
            padding: 15px 12px;
            border-bottom: 1px solid #f3f4f6;
            font-size: 14px;
        }
        tr:hover { background: #f9fafb; }
        tr:last-child td { border-bottom: none; }
        
        .footer {
            background: #f9fafb;
            padding: 20px 40px;
            text-align: center;
            color: #6b7280;
            font-size: 13px;
            border-top: 1px solid #e5e7eb;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>
                <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="2" y="3" width="20" height="14" rx="2"></rect>
                    <line x1="8" y1="21" x2="16" y2="21"></line>
                    <line x1="12" y1="17" x2="12" y2="21"></line>
                </svg>
                System Inventory Report
            </h1>
            <p>Generated: $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss")</p>
        </div>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-label">Total Computers</div>
                <div class="stat-value">$($Data.Count)</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Successful Scans</div>
                <div class="stat-value" style="color:#10b981;">$successCount</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Failed Scans</div>
                <div class="stat-value" style="color:#ef4444;">$failCount</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Total RAM</div>
                <div class="stat-value">$([math]::Round($totalRAM, 0))<span class="stat-unit">GB</span></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Total Storage</div>
                <div class="stat-value">$([math]::Round($totalStorage, 0))<span class="stat-unit">GB</span></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Avg Software/PC</div>
                <div class="stat-value">$([math]::Round(($Data | Where-Object {$_.InstalledSoftwareCount} | Measure-Object InstalledSoftwareCount -Average).Average, 0))</div>
            </div>
        </div>
        
        <div class="content">
            <h2>📊 Detailed Inventory</h2>
            <table>
                <thead>
                    <tr>
                        <th>Computer</th>
                        <th>Status</th>
                        <th>Hardware</th>
                        <th>Operating System</th>
                        <th>Processor</th>
                        <th>RAM</th>
                        <th>Storage</th>
                        <th>IP Address</th>
                        <th>Software</th>
                    </tr>
                </thead>
                <tbody>
                    $tableRows
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>System Inventory Tool v2.0 | Powered by PowerShell</p>
        </div>
    </div>
</body>
</html>
"@
}

#endregion

#region Main Script

# Initialize
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = "$OutputPath\Transcript-$timestamp.txt"      # PowerShell transcript
$script:AppLogFile = "$OutputPath\Application-$timestamp.log"  # Application log
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   System Inventory Tool - Enterprise Edition      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

try {
    # Create output directory first (before any logging)
    if (!(Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    
    # Start logging
    Start-Transcript -Path $script:LogFile -Append | Out-Null
    
    # Run prerequisite checks
    Test-Prerequisites
    
    # Get target computers
    $computers = Get-TargetComputers
    
    Write-Host ""
    Write-Log "Starting inventory collection for $($computers.Count) computer(s)..." -Level Info
    Write-Host ""
    
    # Collect inventory
    $results = @()
    $current = 0
    
    if ($Parallel -and $computers.Count -gt 1) {
        Write-Log "Using parallel processing with throttle limit: $ThrottleLimit" -Level Info
        
        $results = $computers | ForEach-Object -Parallel {
            $computer = $_
            $cred = $using:Credential
            
            # Import function into parallel scope
            function Get-ComputerInventory {
                param([string]$Computer, [PSCredential]$Cred)
                # ... (same function as above)
            }
            
            try {
                Get-ComputerInventory -Computer $computer -Cred $cred
            }
            catch {
                [PSCustomObject]@{
                    ComputerName = $computer
                    Status = "Failed"
                    ErrorMessage = $_.Exception.Message
                    ScanDate = Get-Date
                }
            }
        } -ThrottleLimit $ThrottleLimit
    }
    else {
        # Sequential processing
        foreach ($computer in $computers) {
            $current++
            
            Write-Progress -Activity "Collecting Inventory" `
                -Status "Processing: $computer ($current of $($computers.Count))" `
                -PercentComplete (($current / $computers.Count) * 100)
            
            # Test connectivity
            $connTest = Test-ComputerConnectivity -Computer $computer
            
            if (!$connTest.Success) {
                Write-Log "✗ $computer - $($connTest.Error)" -Level Warning
                $results += [PSCustomObject]@{
                    ComputerName = $computer
                    Status = "Failed"
                    ErrorMessage = $connTest.Error
                    ScanDate = Get-Date
                }
                continue
            }
            
            # Collect inventory
            try {
                $inventory = Get-ComputerInventory -Computer $computer -Cred $Credential
                $results += $inventory
                
                if ($inventory.Status -eq "Success") {
                    Write-Log "✓ $computer - Success" -Level Success
                }
                else {
                    Write-Log "✗ $computer - $($inventory.ErrorMessage)" -Level Warning
                }
            }
            catch {
                Write-Log "✗ $computer - $($_.Exception.Message)" -Level Error
                $results += [PSCustomObject]@{
                    ComputerName = $computer
                    Status = "Failed"
                    ErrorMessage = $_.Exception.Message
                    ScanDate = Get-Date
                }
            }
        }
    }
    
    Write-Progress -Activity "Collecting Inventory" -Completed
    
    # Export results
    Write-Host ""
    Write-Log "Exporting results..." -Level Info
    Export-Results -Data $results -BasePath $OutputPath -Formats $ExportFormat
    
    # Summary
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║               Collection Complete!                 ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    
    $successCount = ($results | Where-Object {$_.Status -eq "Success"}).Count
    $failCount = ($results | Where-Object {$_.Status -eq "Failed"}).Count
    
    Write-Log "Total Computers: $($results.Count)" -Level Info
    Write-Log "Successful: $successCount" -Level Success
    Write-Log "Failed: $failCount" -Level $(if($failCount -gt 0){'Warning'}else{'Success'})
    Write-Log "Output Directory: $OutputPath" -Level Info
    Write-Host ""
    
}
catch {
    Write-Log "Critical error: $($_.Exception.Message)" -Level Error
    throw
}
finally {
    Stop-Transcript | Out-Null
}

#endregion