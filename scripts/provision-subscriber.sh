#!/bin/bash
# provision-subscriber.sh - Add default subscriber to MongoDB

echo "Provisioning default subscriber..."

# Wait for MongoDB to be ready
echo "  Waiting for MongoDB to be ready..."
for i in {1..30}; do
    if docker exec mongodb mongo --eval "db.runCommand('ping').ok" free5gc > /dev/null 2>&1; then
        echo "  MongoDB is ready"
        break
    fi
    sleep 1
done

# Add subscriber (using lowercase free5gc)
echo "  Adding subscriber: IMSI 208930000000001"
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.authenticationData.authenticationSubscription.insertOne({
  "ueId": "imsi-208930000000001",
  "authenticationMethod": "5G_AKA",
  "encPermanentKey": "8baf473f2f8fd09487cccbd7097c6862",
  "authenticationManagementField": "8000",
  "algorithmId": "milenage",
  "encOpcKey": "8e27b6af0e692e750f32667a3b14605d",
  "sequenceNumber": {"sqn": "000000000000", "sqnScheme": "NON_TIME_BASED", "lastIndexes": {}}
})
'

# Add AMF data
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.authenticationData.authenticationStatus.insertOne({
  "ueId": "imsi-208930000000001",
  "nfInstanceId": "00000000-0000-0000-0000-000000000000",
  "success": true,
  "timeStamp": "2026-01-01T00:00:00Z",
  "authType": "5G_AKA"
})
'

# Add access and mobility data
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.amData.insertOne({
  "ueId": "imsi-208930000000001",
  "servingPlmnId": "20893",
  "gpsis": ["msisdn-0900000000"],
  "subscribedUeAmbr": {
    "uplink": "1 Gbps",
    "downlink": "2 Gbps"
  }
})
'

# Add session management subscription data
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.smData.insertOne({
  "ueId": "imsi-208930000000001",
  "servingPlmnId": "20893",
  "singleNssai": {
    "sst": 1,
    "sd": "010203"
  },
  "dnnConfigurations": {
    "internet": {
      "pduSessionTypes": {
        "defaultSessionType": "IPV4",
        "allowedSessionTypes": ["IPV4"]
      },
      "sscModes": {
        "defaultSscMode": "SSC_MODE_1",
        "allowedSscModes": ["SSC_MODE_1", "SSC_MODE_2", "SSC_MODE_3"]
      },
      "5gQosProfile": {
        "5qi": 9,
        "arp": {
          "priorityLevel": 8
        },
        "priorityLevel": 8
      },
      "sessionAmbr": {
        "uplink": "1000 Mbps",
        "downlink": "1000 Mbps"
      }
    }
  }
})
'

echo "  Subscriber provisioned successfully"
echo "  IMSI: 208930000000001"
echo "  K: 8baf473f2f8fd09487cccbd7097c6862"
echo "  OPc: 8e27b6af0e692e750f32667a3b14605d"
