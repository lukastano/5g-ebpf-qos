#!/bin/bash
# provision-subscriber.sh - Add default subscriber to MongoDB (WebUI format)

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

# Clean up old subscriber data
echo "  Cleaning up old subscriber data..."
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.authenticationData.authenticationSubscription.deleteMany({"ueId": "imsi-208930000000003"});
db.subscriptionData.authenticationData.authenticationStatus.deleteMany({"ueId": "imsi-208930000000003"});
db.subscriptionData.provisionedData.amData.deleteMany({"ueId": "imsi-208930000000003"});
db.subscriptionData.provisionedData.smData.deleteMany({"ueId": "imsi-208930000000003"});
db.subscriptionData.provisionedData.smfSelectionSubscriptionData.deleteMany({"ueId": "imsi-208930000000003"});
' > /dev/null 2>&1

# Add subscriber - using IMSI 208930000000003 (default WebUI format)
echo "  Adding subscriber: IMSI 208930000000003"

# Authentication subscription
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.authenticationData.authenticationSubscription.insertOne({
  "ueId": "imsi-208930000000003",
  "authenticationMethod": "5G_AKA", 
  "encPermanentKey": "8baf473f2f8fd09487cccbd7097c6862",
  "authenticationManagementField": "8000",
  "algorithmId": "milenage",
  "encOpcKey": "8e27b6af0e692e750f32667a3b14605d",
  "sequenceNumber": {
    "sqn": "000000000000",
    "sqnScheme": "NON_TIME_BASED",
    "lastIndexes": {}
  }
});
' > /dev/null 2>&1

# Access and Mobility subscription
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.amData.insertOne({
  "ueId": "imsi-208930000000003",
  "servingPlmnId": "20893",
  "subscribedUeAmbr": {
    "uplink": "2 Gbps",
    "downlink": "1 Gbps"
  },
  "gpsis": ["msisdn-0900000000"]
});
' > /dev/null 2>&1

# SMF Selection subscription  
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.smfSelectionSubscriptionData.insertOne({
  "ueId": "imsi-208930000000003",
  "servingPlmnId": "20893",
  "subscribedSnssaiInfos": {
    "01010203": {
      "dnnInfos": [
        {"dnn": "internet"}
      ]
    },
    "01112233": {
      "dnnInfos": [
        {"dnn": "internet"}
      ]
    }
  }
});
' > /dev/null 2>&1

# Session Management subscription
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.smData.insertOne({
  "ueId": "imsi-208930000000003",
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
        "uplink": "200 Mbps",
        "downlink": "100 Mbps"  
      }
    }
  }
});
' > /dev/null 2>&1

# Add second slice
docker exec mongodb mongo free5gc --eval '
db.subscriptionData.provisionedData.smData.insertOne({
  "ueId": "imsi-208930000000003",
  "servingPlmnId": "20893",
  "singleNssai": {
    "sst": 1,
    "sd": "112233"
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
        "5qi": 8,
        "arp": {
          "priorityLevel": 8
        },
        "priorityLevel": 8
      },
      "sessionAmbr": {
        "uplink": "200 Mbps",
        "downlink": "100 Mbps"
      }
    }
  }
});
' > /dev/null 2>&1

echo "  Subscriber provisioned successfully"
echo "  IMSI: 208930000000003"
echo "  K: 8baf473f2f8fd09487cccbd7097c6862"
echo "  OPc: 8e27b6af0e692e750f32667a3b14605d"
