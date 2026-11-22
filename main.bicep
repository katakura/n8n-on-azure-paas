targetScope = 'resourceGroup'

// ---- General ----
@description('Region')
param location string = resourceGroup().location

@description('Prefix for resource names')
param namePrefix string = 'n8n'

@description('Suffix for globally unique names (PostgreSQL)')
param uniqueSuffix string = take(uniqueString(resourceGroup().id), 6)

// ---- Network ----
@description('VNet address space. Avoid overlapping with the hub or other spokes')
param vnetAddressPrefixes array = ['192.168.41.0/24']

@description('Subnet for the Container Apps environment (/27 or larger, delegated to Microsoft.App/environments)')
param acaSubnetPrefix string = '192.168.41.0/27'

@description('Subnet for PostgreSQL (delegated to Microsoft.DBforPostgreSQL/flexibleServers)')
param pgSubnetPrefix string = '192.168.41.32/28'

// ---- PostgreSQL ----
@description('PostgreSQL version')
param pgVersion string = '16'

@description('PostgreSQL SKU')
param pgSkuName string = 'Standard_B1ms'

@description('PostgreSQL tier')
param pgTier string = 'Burstable'

@description('PostgreSQL storage (GB)')
param pgStorageSizeGB int = 32

@description('PostgreSQL administrator login')
param pgAdminLogin string = 'n8nadmin'

@description('PostgreSQL administrator password. If empty, it is derived from uniqueString, which is deterministic and not random (for verification use only)')
@secure()
param pgAdminPassword string = ''

@description('Database name used by n8n')
param pgDatabaseName string = 'n8n'

// ---- App ----
@description('n8n container image (pinned tag)')
param n8nImage string = 'docker.io/n8nio/n8n:2.46.6'

@description('Container CPU (vCPU)')
param containerCpu string = '1'

@description('Container memory')
param containerMemory string = '2Gi'

@description('Encryption key for stored credentials (N8N_ENCRYPTION_KEY). Without a persistent volume, n8n cannot start if this value differs from the one the database was created with, so keep the same value on every deployment')
@secure()
param n8nEncryptionKey string

@description('Source IPs/CIDRs allowed to reach n8n (e.g. 203.0.113.10/32). The first visitor becomes the owner of an n8n instance, so leaving this empty exposes the setup page to the whole internet until you create the owner account')
param allowedIpRanges array = []

@description('Time zone for schedule triggers (GENERIC_TIMEZONE)')
param timeZone string = 'Asia/Tokyo'

@description('Send AVM usage telemetry')
param enableTelemetry bool = true

var vnetName = 'vnet-${namePrefix}'
var pgDnsZoneName = '${namePrefix}.private.postgres.database.azure.com'
var appName = 'ca-${namePrefix}'
// Prefix with Pg1 to satisfy the complexity requirements (upper case, lower case, digits). Use the specified password if there is one
var generatedPgPassword = 'Pg1${uniqueString(subscription().subscriptionId, resourceGroup().id, 'pg-admin-1')}${uniqueString(resourceGroup().id, namePrefix, 'pg-admin-2')}'
var pgPassword = empty(pgAdminPassword) ? generatedPgPassword : pgAdminPassword

// ---- Logs ----
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-${uniqueString(deployment().name)}'
  params: {
    name: 'log-${namePrefix}'
    location: location
    enableTelemetry: enableTelemetry
    dataRetention: 30
    dailyQuotaGb: '1'
  }
}

// ---- Network ----
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-${uniqueString(deployment().name)}'
  params: {
    name: vnetName
    location: location
    enableTelemetry: enableTelemetry
    addressPrefixes: vnetAddressPrefixes
    subnets: [
      {
        name: 'snet-aca'
        addressPrefix: acaSubnetPrefix
        delegation: 'Microsoft.App/environments'
      }
      {
        name: 'snet-pg'
        addressPrefix: pgSubnetPrefix
        delegation: 'Microsoft.DBforPostgreSQL/flexibleServers'
      }
    ]
  }
}

var acaSubnetId = vnet.outputs.subnetResourceIds[0]
var pgSubnetId = vnet.outputs.subnetResourceIds[1]

// ---- Private DNS zone for PostgreSQL ----
module dnsPostgres 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-pg-${uniqueString(deployment().name)}'
  params: {
    name: pgDnsZoneName
    enableTelemetry: enableTelemetry
    virtualNetworkLinks: [
      { virtualNetworkResourceId: vnet.outputs.resourceId, registrationEnabled: false }
    ]
  }
}

// ---- PostgreSQL (VNet integration) ----
module postgres 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.16.1' = {
  name: 'pg-${uniqueString(deployment().name)}'
  params: {
    name: 'pg-${namePrefix}-${uniqueSuffix}'
    location: location
    enableTelemetry: enableTelemetry
    skuName: pgSkuName
    tier: pgTier
    version: pgVersion
    storageSizeGB: pgStorageSizeGB
    availabilityZone: -1
    highAvailability: 'Disabled'
    geoRedundantBackup: 'Disabled'
    backupRetentionDays: 7
    // Advanced threat protection (Defender) may incur costs, so disable it for verification
    enableAdvancedThreatProtection: false
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgPassword
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    delegatedSubnetResourceId: pgSubnetId
    privateDnsZoneArmResourceId: dnsPostgres.outputs.resourceId
    publicNetworkAccess: 'Disabled'
    databases: [
      { name: pgDatabaseName }
    ]
  }
}

// ---- Container Apps environment (VNet integration, Consumption) ----
module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'cae-${uniqueString(deployment().name)}'
  params: {
    name: 'cae-${namePrefix}'
    location: location
    enableTelemetry: enableTelemetry
    infrastructureSubnetResourceId: acaSubnetId
    internal: false
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
  }
}

// ---- n8n ----
// The public URL of an external-ingress app is https://<app name>.<environment default domain>.
// Building it from the environment output avoids a circular reference to the app itself
var n8nUrl = 'https://${appName}.${containerAppsEnv.outputs.defaultDomain}/'
var pgFqdn = postgres.outputs.?fqdn ?? ''

var containerEnv = [
  // PostgreSQL (the default is SQLite)
  { name: 'DB_TYPE', value: 'postgresdb' }
  { name: 'DB_POSTGRESDB_HOST', value: pgFqdn }
  { name: 'DB_POSTGRESDB_PORT', value: '5432' }
  { name: 'DB_POSTGRESDB_DATABASE', value: pgDatabaseName }
  { name: 'DB_POSTGRESDB_USER', value: pgAdminLogin }
  { name: 'DB_POSTGRESDB_PASSWORD', secretRef: 'db-password' }
  { name: 'DB_POSTGRESDB_SSL_ENABLED', value: 'true' }
  // The state lives in PostgreSQL and no volume is mounted, so the key must be fixed
  { name: 'N8N_ENCRYPTION_KEY', secretRef: 'encryption-key' }
  // Behind the Container Apps ingress (one reverse proxy)
  { name: 'N8N_WEBHOOK_URL', value: n8nUrl }
  { name: 'N8N_PROXY_HOPS', value: '1' }
  { name: 'GENERIC_TIMEZONE', value: timeZone }
  { name: 'TZ', value: timeZone }
]

module n8n 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'ca-${uniqueString(deployment().name)}'
  params: {
    name: appName
    location: location
    enableTelemetry: enableTelemetry
    environmentResourceId: containerAppsEnv.outputs.resourceId
    workloadProfileName: 'Consumption'
    ingressExternal: true
    ingressTargetPort: 5678
    ingressAllowInsecure: false
    ipSecurityRestrictions: [for (cidr, i) in allowedIpRanges: {
      name: 'allow-${i}'
      ipAddressRange: cidr
      action: 'Allow'
    }]
    activeRevisionsMode: 'Single'
    // Multiple main instances of n8n require an Enterprise license, so run exactly one replica
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 1
    }
    secrets: [
      { name: 'db-password', value: pgPassword }
      { name: 'encryption-key', value: n8nEncryptionKey }
    ]
    containers: [
      {
        name: 'n8n'
        image: n8nImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: containerEnv
        probes: [
          {
            type: 'Startup'
            httpGet: { path: '/healthz', port: 5678 }
            periodSeconds: 10
            failureThreshold: 60
            timeoutSeconds: 5
          }
          {
            type: 'Liveness'
            httpGet: { path: '/healthz', port: 5678 }
            periodSeconds: 30
            timeoutSeconds: 5
          }
        ]
      }
    ]
  }
}

output n8nUrl string = n8nUrl
output n8nFqdn string = n8n.outputs.fqdn
output postgresFqdn string = postgres.outputs.?fqdn ?? ''
