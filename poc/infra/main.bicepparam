using 'main.bicep'

// The scripts pass the key through an environment variable so the .pub file contents never need editing here.
param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY')

param prefix = readEnvironmentVariable('POC_PREFIX', 'acapoc')
param vmSize = readEnvironmentVariable('VM_SIZE', 'Standard_D2as_v5')
param buildInstanceCount = int(readEnvironmentVariable('BUILD_INSTANCE_COUNT', '2'))
param deployInstanceCount = int(readEnvironmentVariable('DEPLOY_INSTANCE_COUNT', '1'))
param appName = readEnvironmentVariable('ACA_APP', 'hello-poc')
