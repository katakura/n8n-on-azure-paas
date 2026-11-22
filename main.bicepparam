using 'main.bicep'

// Values to adapt to your environment
param location = 'japaneast'
param namePrefix = 'n8n'

// Avoid overlapping with the hub or other spokes
param vnetAddressPrefixes = ['192.168.41.0/24']
param acaSubnetPrefix = '192.168.41.0/27'
param pgSubnetPrefix = '192.168.41.32/28'

param pgVersion = '16'
param pgSkuName = 'Standard_B1ms'
param pgTier = 'Burstable'
param pgStorageSizeGB = 32

param n8nImage = 'docker.io/n8nio/n8n:2.46.6'
param timeZone = 'Asia/Tokyo'

// Secrets and the administrator name are read from environment variables (set by deploy.sh). Do not write them in the repository
param pgAdminLogin = readEnvironmentVariable('PG_ADMIN_LOGIN', 'n8nadmin')
// If empty, main.bicep derives it from uniqueString
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param n8nEncryptionKey = readEnvironmentVariable('N8N_ENCRYPTION_KEY')

// Comma-separated CIDRs from the ALLOWED_IPS environment variable (set by deploy.sh -i). Empty means unrestricted
param allowedIpRanges = filter(map(split(readEnvironmentVariable('ALLOWED_IPS', ''), ','), r => trim(r)), r => !empty(r))
