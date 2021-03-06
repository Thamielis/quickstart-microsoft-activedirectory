[CmdletBinding()]
# Incoming Parameters for Script, CloudFormation\SSM Parameters being passed in
param(
    [Parameter(Mandatory=$true)]
    [string]$ADServer1NetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory=$true)]
    [string]$ADAdminSecParam,

    [Parameter(Mandatory=$true)]
    [string]$ADAltUserSecParam,

    [Parameter(Mandatory=$true)]
    [string]$RestoreModeSecParam,

    [Parameter(Mandatory=$true)]
    [string]$SiteName,

    [Parameter(Mandatory=$true)]
    [string]$VPCCIDR
)

# Grabbing VPC DNS IP in order to set DNS Forwarder for AD DNS
$VPCDNS = (Get-NetIPConfiguration).DNSServer.ServerAddresses
# Grabbing the Current Gateway Address in order to Static IP Correctly
$GatewayAddress = (Get-NetIPConfiguration).IPv4DefaultGateway.NextHop
# Formatting IP Address in format needed for IPAdress DSC Resource
$IPADDR = 'IP/CIDR' -replace 'IP',(Get-NetIPConfiguration).IPv4Address.IpAddress -replace 'CIDR',(Get-NetIPConfiguration).IPv4Address.PrefixLength
# Grabbing Mac Address for Primary Interface to Rename Interface
$MacAddress = (Get-NetAdapter).MacAddress
# Getting Password from Secrets Manager for AD Admin User
$ADAdminPassword = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $ADAdminSecParam).SecretString
# Getting Password from Secrets Manager for AD Alternate User
$AltUserPassword = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $ADAltUserSecParam).SecretString
# Getting Password from Secrets Manager for AD Admin User
$RestoreModePassword = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $RestoreModeSecParam).SecretString
# Creating Credential Object for Administrator
$Credentials = (New-Object PSCredential($ADAdminPassword.UserName,(ConvertTo-SecureString $ADAdminPassword.Password -AsPlainText -Force)))
# Creating Credential Object for Alternate Domain Admin
$AltCredentials = (New-Object PSCredential($AltUserPassword.UserName,(ConvertTo-SecureString $AltUserPassword.Password -AsPlainText -Force)))
# Creating Credential Object for Restore Mode Password
$RestoreCredentials = (New-Object PSCredential($RestoreModePassword.UserName,(ConvertTo-SecureString $RestoreModePassword.Password -AsPlainText -Force)))
# Getting the DSC Cert Encryption Thumbprint to Secure the MOF File
$DscCertThumbprint = (get-childitem -path cert:\LocalMachine\My | where { $_.subject -eq "CN=AWSQSDscEncryptCert" }).Thumbprint

# Creating Configuration Data Block that has the Certificate Information for DSC Configuration Processing
$ConfigurationData = @{
    AllNodes = @(
        @{
            NodeName="*"
            CertificateFile = "C:\AWSQuickstart\publickeys\AWSQSDscPublicKey.cer"
            Thumbprint = $DscCertThumbprint
        },
        @{
            NodeName = 'localhost'
        }
    )
}

# PowerShell DSC Configuration Block for Domain Controller 1
Configuration ConfigDC1 {
    # Credential Objects being passed in
    param
    (
        [PSCredential] $Credentials,
        [PSCredential] $AltCredentials,
        [PSCredential] $RestoreCredentials
    )
    
    # Importing DSC Modules needed for Configuration
    Import-Module -Name PSDesiredStateConfiguration
    Import-Module -Name xActiveDirectory
    Import-Module -Name NetworkingDsc
    Import-Module -Name ActiveDirectoryCSDsc
    Import-Module -Name ComputerManagementDsc
    Import-Module -Name xDnsServer
    
    # Importing All DSC Resources needed for Configuration
    Import-DscResource -Module PSDesiredStateConfiguration
    Import-DscResource -Module NetworkingDsc
    Import-DscResource -Module xActiveDirectory
    Import-DscResource -Module ActiveDirectoryCSDsc
    Import-DscResource -Module ComputerManagementDsc
    Import-DscResource -Module xDnsServer
  
    
    # Node Configuration block, since processing directly on DC using localhost
    Node 'localhost' {

        # Renaming Primary Adapter in order to Static the IP for AD installation
        NetAdapterName RenameNetAdapterPrimary {
            NewName    = 'Primary'
            MacAddress = $MacAddress
        }

        # Changing the Local Administrator Password, this account will be a Domain Admin
        User AdministratorPassword {
            UserName = "Administrator"
            Password = $Credentials
        }

        # Renaming Computer to ADServer2NetBIOSName Parameter
        Computer NewName {
            Name = $ADServer1NetBIOSName
        }
        
        # Disabling DHCP on the Primary Interface
        NetIPInterface DisableDhcp {
            Dhcp           = 'Disabled'
            InterfaceAlias = 'Primary'
            AddressFamily  = 'IPv4'
            DependsOn = '[NetAdapterName]RenameNetAdapterPrimary'
        }

        # Setting the IP Address on the Primary Interface
        IPAddress SetIP {
            IPAddress = $IPADDR
            InterfaceAlias = 'Primary'
            AddressFamily = 'IPv4'
            DependsOn = '[NetAdapterName]RenameNetAdapterPrimary'
        }

        # Setting Default Gateway on Primary Interface
        DefaultGatewayAddress SetDefaultGateway {
            Address        = $GatewayAddress
            InterfaceAlias = 'Primary'
            AddressFamily  = 'IPv4'
            DependsOn = '[NetAdapterName]RenameNetAdapterPrimary'
        }
        
        # Setting DNS Server on Primary Interface to point to itself
        DnsServerAddress DnsServerAddress {
            Address        = '127.0.0.1'
            InterfaceAlias = 'Primary'
            AddressFamily  = 'IPv4'
            DependsOn = "[WindowsFeature]DNS"
        }

        # Adding Needed Windows Features
        WindowsFeature DNS {
            Ensure = "Present"
            Name = "DNS"
        }

        WindowsFeature AD-Domain-Services {
            Ensure = "Present"
            Name = "AD-Domain-Services"
        }
        
        WindowsFeature RSAT-DNS-Server {
            Ensure = "Present"
            Name = "RSAT-DNS-Server"
            DependsOn = "[WindowsFeature]DNS"
        }
        
        WindowsFeature RSAT-AD-Tools {
            Name = 'RSAT-AD-Tools'
            Ensure = 'Present'
            DependsOn = "[WindowsFeature]AD-Domain-Services"
        }
        
        WindowsFeature RSAT-ADDS {
            Ensure = "Present"
            Name = "RSAT-ADDS"
            DependsOn = "[WindowsFeature]AD-Domain-Services"
        }
        
        WindowsFeature RSAT-ADDS-Tools {
            Name = 'RSAT-ADDS-Tools'
            Ensure = 'Present'
            DependsOn = "[WindowsFeature]RSAT-ADDS"
        }
        
        WindowsFeature RSAT-AD-AdminCenter {
            Name = 'RSAT-AD-AdminCenter'
            Ensure = 'Present'
            DependsOn = "[WindowsFeature]AD-Domain-Services"
        }

        WindowsFeature ADCS-Cert-Authority { 
            Ensure = 'Present' 
            Name = 'ADCS-Cert-Authority'
            DependsOn = '[xADDomain]PrimaryDC' 
        }
         
        ADCSCertificationAuthority ADCS { 
            Ensure = 'Present'
            IsSingleInstance = 'Yes' 
            Credential = $Credentials
            CAType = 'EnterpriseRootCA' 
            DependsOn = '[WindowsFeature]ADCS-Cert-Authority'               
        }

        WindowsFeature ADCS-Web-Enrollment { 
            Ensure = 'Present' 
            Name = 'ADCS-Web-Enrollment' 
            DependsOn = '[WindowsFeature]ADCS-Cert-Authority' 
        }

        WindowsFeature RSAT-ADCS { 
            Ensure = 'Present' 
            Name = 'RSAT-ADCS' 
            DependsOn = '[WindowsFeature]ADCS-Cert-Authority' 
        } 
        
        WindowsFeature RSAT-ADCS-Mgmt { 
            Ensure = 'Present' 
            Name = 'RSAT-ADCS-Mgmt' 
            DependsOn = '[WindowsFeature]ADCS-Cert-Authority' 
        } 
        
        # Promoting Node as Secondary DC
        ADDomainController SecondaryDC {
            DomainName = $DomainDnsName
            DomainAdministratorCredential = $Credentials
            SafemodeAdministratorPassword = $Credentials
            DependsOn = @("[WindowsFeature]AD-Domain-Services","[Computer]JoinDomain")
        }

        # Renaming Default AD Site to Region Name
        ADReplicationSite RegionSite {
            Name = $SiteName
            DependsOn = "[xADDomain]PrimaryDC"
        }

        # Adding AZ Subnets to AD Site
        ADReplicationSubnet VPCCIDR {
            Name = $VPCCIDR
            Site = $SiteName
            DependsOn = "[xADReplicationSite]RegionSite"
        }

        # Setting VPC DNS as a forwarder for AD DNS
        xDnsServerForwarder ForwardtoVPCDNS {
            IsSingleInstance = 'Yes'
            IPAddresses = $VPCDNS
        }
    }
}

# Generating MOF File
ConfigDC1 -OutputPath 'C:\AWSQuickstart\ConfigDC1' -Credentials $Credentials -AltCredentials $AltCredentials -RestoreCredentials $RestoreCredentials -ConfigurationData $ConfigurationData