@description('Name of the target Azure Virtual Machine to monitor and deallocate.')
param vmName string

@description('Azure region for the Logic App workflow (defaults to resource group location).')
param location string = resourceGroup().location

@description('Secret ntfy topic name for receiving mobile push notifications.')
param ntfyTopic string

@description('ntfy server base URL.')
param ntfyServerUrl string = 'https://ntfy.sh'

@description('Name of the Logic App workflow to create.')
param logicAppName string = 'la-${vmName}-shutdown-action'

// Built-in Role Definition ID for "Virtual Machine Contributor"
var vmContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')

resource existingVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource shutdownLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'GET'
          }
        }
      }
      actions: {
        Check_Decision: {
          type: 'If'
          expression: {
            and: [
              {
                equals: [
                  '@triggerOutputs()?[\'queries\']?[\'decision\']'
                  'approve'
                ]
              }
            ]
          }
          actions: {
            Response_Approved: {
              type: 'Response'
              kind: 'Http'
              inputs: {
                statusCode: 200
                body: {
                  status: 'shutting_down'
                }
              }
              runAfter: {}
            }
            Deallocate_VM: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: '${environment().resourceManager}${existingVm.id}/deallocate?api-version=2024-07-01'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: environment().resourceManager
                }
              }
              runAfter: {
                Response_Approved: [
                  'Succeeded'
                ]
              }
            }
            Notify_Shutdown_Complete: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: ntfyServerUrl
                headers: {
                  'Content-Type': 'application/json; charset=utf-8'
                }
                body: {
                  topic: ntfyTopic
                  title: '${vmName} stopped'
                  message: 'VM deallocated. Billing paused.'
                  priority: 3
                  tags: [
                    'white_check_mark'
                  ]
                }
              }
              runAfter: {
                Deallocate_VM: [
                  'Succeeded'
                ]
              }
            }
          }
          else: {
            actions: {
              Response_Skipped: {
                type: 'Response'
                kind: 'Http'
                inputs: {
                  statusCode: 200
                  body: {
                    status: 'skipped'
                  }
                }
                runAfter: {}
              }
              Notify_Skipped: {
                type: 'Http'
                inputs: {
                  method: 'POST'
                  uri: ntfyServerUrl
                  headers: {
                    'Content-Type': 'application/json; charset=utf-8'
                  }
                  body: {
                    topic: ntfyTopic
                    title: 'Shutdown skipped'
                    message: '${vmName} stays running (snoozed 1h).'
                    priority: 2
                    tags: [
                      'clock1'
                    ]
                  }
                }
                runAfter: {
                  Response_Skipped: [
                    'Succeeded'
                  ]
                }
              }
            }
          }
          runAfter: {}
        }
      }
      outputs: {}
    }
  }
}

resource vmRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingVm.id, shutdownLogicApp.id, vmContributorRoleId)
  scope: existingVm
  properties: {
    roleDefinitionId: vmContributorRoleId
    principalId: shutdownLogicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output logicAppName string = shutdownLogicApp.name
output logicAppPrincipalId string = shutdownLogicApp.identity.principalId
output callbackUrl string = listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', shutdownLogicApp.name, 'manual'), '2019-05-01').value
