#!/usr/bin/env bash
# Fichier de réponses de l'installation automatique de Windows 11
# (autounattend.xml), écrit sur la sortie standard.
#
#   windows-autounattend.sh <efi|pcbios> [<préfixe du nom des PC>]
#
# efi ou pcbios : valeur de ${platform} dans iPXE ; seul le partitionnement
# change (GPT pour l'UEFI, MBR pour le BIOS).
#
# Ce que fait l'installation, sans aucune question :
#   - français partout : installation, Windows, clavier AZERTY, fuseau horaire
#     de Paris ;
#   - efface le disque 0 et le repartitionne ;
#   - Windows 11 Famille (clé générique publique de Microsoft : installe sans
#     activer ; l'activation se fait seule si la carte mère porte une licence) ;
#   - contrôles TPM 2.0, Secure Boot, processeur et mémoire désactivés par
#     install.bat (HKLM\SYSTEM\Setup\LabConfig, dans WinPE) ;
#   - compte local « Utilisateur », administrateur, sans mot de passe ; aucun
#     écran au premier démarrage (pas de compte Microsoft, confidentialité au
#     plus restrictif) ;
#   - nom du PC : <préfixe>-<numéro de série du firmware>, 15 caractères au
#     plus ; nom aléatoire de Windows si le numéro est absent ou générique.
set -Eeuo pipefail

plateforme="${1:-}"
prefixe="${2:-ANS}"
[[ "$plateforme" == efi || "$plateforme" == pcbios ]] || { echo "usage : $0 <efi|pcbios> [<préfixe>]" >&2; exit 2; }
[[ "$prefixe" =~ ^[A-Za-z0-9]{1,6}$ ]] || { echo "préfixe : 1 à 6 lettres ou chiffres" >&2; exit 2; }

# Nom de l'image dans install.wim (wiminfo) et clé générique de cette édition.
IMAGE="Windows 11 Home"
CLE="YTMG3-N6DKC-DKB77-7M9GH-8HVX7"

if [[ "$plateforme" == efi ]]; then
  partitions='<CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>'
  partition_windows=3
else
  partitions='<CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System</Label><Active>true</Active></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>'
  partition_windows=2
fi

# Nom du PC, posé au passage specialize dans le registre (ComputerName et
# nom d'hôte TCP/IP), pris en compte au redémarrage qui suit. Pas de
# ComputerName dans ce fichier : Windows tire un nom aléatoire, gardé si le
# numéro de série est inutilisable.
# Une commande de RunSynchronous est limitée à 259 caractères : le script est
# rangé dans <BITS> (espace de noms à nous, ignoré par Windows), relu dans la
# copie que Windows garde du fichier (C:\Windows\Panther\unattend.xml).
nommage="\$s = ((Get-CimInstance Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]', '').ToUpper()
if (\$s.Length -ge 3 -and \$s -notmatch '^(0+|1234567890?|DEFAULT|TOBEFILLED|SYSTEMSERIAL|NONE|NOTAPPLICABLE|NOTSPECIFIED|CHASSISSERIAL|OEM)') {
  \$n = '$prefixe-' + \$s.Substring([Math]::Max(0, \$s.Length - $((14 - ${#prefixe}))))
  Set-ItemProperty -LiteralPath 'Registry::HKLM\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ComputerName' -Name ComputerName -Value \$n
  Set-ItemProperty -LiteralPath 'Registry::HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters' -Name Hostname -Value \$n
  Set-ItemProperty -LiteralPath 'Registry::HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters' -Name 'NV Hostname' -Value \$n
}"

international() {  # international <composant>
  cat <<EOF
    <component name="$1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>040c:0000040c</InputLocale>
      <SystemLocale>fr-FR</SystemLocale>
      <UILanguage>fr-FR</UILanguage>
      <UserLocale>fr-FR</UserLocale>
EOF
}

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Écrit par bits-pxe-server (windows-autounattend.sh, $plateforme) : installation
     automatique de Windows 11, EFFACE LE DISQUE 0. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
$(international Microsoft-Windows-International-Core-WinPE)
      <SetupUILanguage><UILanguage>fr-FR</UILanguage></SetupUILanguage>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          $partitions
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$IMAGE</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>$partition_windows</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <ProductKey><Key>$CLE</Key><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>Romance Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Premier demarrage sans reseau ni compte Microsoft</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Nom du PC d'apres le numero de serie</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([xml](Get-Content -Raw C:\Windows\Panther\unattend.xml)).unattend.BITS.Nommage"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
$(international Microsoft-Windows-International-Core)
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>Utilisateur</Name>
            <DisplayName>Utilisateur</DisplayName>
            <Group>Administrators</Group>
            <Password><Value></Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
  <BITS xmlns="urn:bits-pxe-server:autounattend">
    <Nommage>
$nommage
    </Nommage>
  </BITS>
</unattend>
EOF
