#Requires -Version 5.1
BeforeAll {
 Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
 $script:statusPath=Join-Path $PSScriptRoot '..\ProxyStatus.ps1'
}
Describe 'Route deletion revalidates the reason, not just the interface number' {
 BeforeEach {
  InModuleScope ProxyClean.Common {
   $script:target=[pscustomobject]@{InterfaceIndex=2;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.2';RouteMetric=5}
   $script:physical=[pscustomobject]@{InterfaceIndex=1;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10}
   Mock Get-NetAdapter { @([pscustomobject]@{InterfaceIndex=1;HardwareInterface=$true;Status='Up'},[pscustomobject]@{InterfaceIndex=2;HardwareInterface=$false;Status='Up'}) }
   Mock Get-NetRoute { @($script:physical,$script:target) }
   Mock Remove-NetRoute {}
  }
 }
 It 'preserves a route when its previously disconnected adapter recovered' {
  InModuleScope ProxyClean.Common {
   $step=New-PCStep Route fixture (ConvertTo-PCRouteRecord $script:target) $null 'fixture'
   {Set-PCResourceValue $step $null}|Should -Throw '*recovered*'
   Should -Invoke Remove-NetRoute -Times 0
  }
 }
 It 'still permits explicitly selected active fake-IP cleanup with physical fallback' {
  InModuleScope ProxyClean.Common {
   $script:target.NextHop='198.18.0.1'
   $step=New-PCStep Route fixture (ConvertTo-PCRouteRecord $script:target) $null 'fixture'
   $step|Add-Member -NotePropertyName allow_active_fake -NotePropertyValue $true
   Set-PCResourceValue $step $null
   Should -Invoke Remove-NetRoute -Times 1
  }
 }
}
Describe 'Status entry does not silently perform external exit probes' {
 BeforeEach {
  InModuleScope ProxyClean.Common -Parameters @{Path=$script:statusPath} {
   param($Path)
   $text=[IO.File]::ReadAllText($Path);$text=[regex]::Replace($text,'(?m)^Import-Module[^\r\n]*','')
   $script:entry=[scriptblock]::Create($text)
   Mock Get-PCSnapshot { [pscustomobject]@{availability=[pscustomobject]@{listeners='observed'}} }
   Mock ConvertTo-PCPublicSnapshot { [pscustomobject]@{conclusion=[pscustomobject]@{current_default='not_probed'};exit_probes=@()} }
   Mock Get-PCExitComparison { [pscustomobject]@{status='fixture';address_redacted=$true} }
  }
 }
 It 'defaults to zero external probes' {
  InModuleScope ProxyClean.Common {
   $r=(& $script:entry -Json)|ConvertFrom-Json
   @($r.exit_probes)|Should -HaveCount 0;Should -Invoke Get-PCExitComparison -Times 0
  }
 }
 It 'performs only explicitly requested probes and respects the skip override' {
  InModuleScope ProxyClean.Common {
   $r=(& $script:entry -ProbeExit -Json)|ConvertFrom-Json
   @($r.exit_probes)|Should -HaveCount 1
   $r=(& $script:entry -ProbeExit -SkipExitProbe -Json)|ConvertFrom-Json
   @($r.exit_probes)|Should -HaveCount 0;Should -Invoke Get-PCExitComparison -Times 1
  }
 }
}