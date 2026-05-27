#!/bin/bash
# provision-subscriber.sh - Add default subscriber to MongoDB (WebUI-compatible format)

# Wait for MongoDB to be ready
wait_mongo() {
    echo "  Waiting for MongoDB to be ready..."
    for i in {1..30}; do
        if docker exec mongodb mongo --eval "db.runCommand('ping').ok" free5gc > /dev/null 2>&1; then
            echo "  MongoDB is ready"
            return 0
        fi
        sleep 1
    done
    echo "  Error: MongoDB timeout"
    exit 1
}

add_subscriber() {
    local IMSI=$1
    local K=$2
    local OPC=$3
    local UEID="imsi-$IMSI"

    echo "------------------------------------------"
    echo "Processing UE: $UEID"

    # 1. Clean up old subscriber data
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.authenticationData.authenticationSubscription.deleteMany({"ueId": "'$UEID'"});
    db.subscriptionData.authenticationData.authenticationStatus.deleteMany({"ueId": "'$UEID'"});
    db.subscriptionData.provisionedData.amData.deleteMany({"ueId": "'$UEID'"});
    db.subscriptionData.provisionedData.smData.deleteMany({"ueId": "'$UEID'"});
    db.subscriptionData.provisionedData.smfSelectionSubscriptionData.deleteMany({"ueId": "'$UEID'"});
    ' > /dev/null 2>&1

    # 2. Authentication subscription
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.authenticationData.authenticationSubscription.insertOne({
      "ueId": "'$UEID'",
      "authenticationMethod": "5G_AKA",
      "encPermanentKey": "'$K'",
      "authenticationManagementField": "8000",
      "algorithmId": "milenage",
      "encOpcKey": "'$OPC'",
      "sequenceNumber": {
        "sqn": "000000000000",
        "sqnScheme": "NON_TIME_BASED",
        "lastIndexes": {}
      }
    });
    ' > /dev/null 2>&1

    # 3. Access and Mobility subscription
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.provisionedData.amData.insertOne({
      "ueId": "'$UEID'",
      "servingPlmnId": "20893",
      "subscribedUeAmbr": { "uplink": "1 Gbps", "downlink": "2 Gbps" },
      "gpsis": ["msisdn-"],
      "nssai": {
        "defaultSingleNssais": [{ "sst": 1, "sd": "010203" }],
        "singleNssais": [{ "sst": 1, "sd": "112233" }]
      }
    });
    ' > /dev/null 2>&1

    # 4. SMF Selection subscription
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.provisionedData.smfSelectionSubscriptionData.insertOne({
      "subscribedSnssaiInfos": {
        "01010203": { "dnnInfos": [{"dnn": "internet"}] },
        "01112233": { "dnnInfos": [{"dnn": "internet"}] }
      },
      "ueId": "'$UEID'", "servingPlmnId": "20893"
    });
    ' > /dev/null 2>&1

    # 5. Session Management subscription - slice 1 (010203)
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.provisionedData.smData.insertOne({
      "dnnConfigurations": {
        "internet": {
          "5gQosProfile": { "5qi": 9, "arp": { "preemptCap": "", "preemptVuln": "", "priorityLevel": 8 }, "priorityLevel": 8 },
          "sessionAmbr": { "uplink": "1000 Mbps", "downlink": "1000 Mbps" },
          "pduSessionTypes": { "defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"] },
          "sscModes": { "defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"] }
        }
      },
      "ueId": "'$UEID'", "servingPlmnId": "20893", "singleNssai": { "sd": "010203", "sst": 1 }
    });
    ' > /dev/null 2>&1

    # 6. Session Management subscription - slice 2 (112233)
    docker exec mongodb mongo free5gc --eval '
    db.subscriptionData.provisionedData.smData.insertOne({
      "dnnConfigurations": {
        "internet": {
          "5gQosProfile": { "5qi": 8, "arp": { "preemptCap": "", "preemptVuln": "", "priorityLevel": 8 }, "priorityLevel": 8 },
          "sessionAmbr": { "uplink": "1000 Mbps", "downlink": "1000 Mbps" },
          "pduSessionTypes": { "defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"] },
          "sscModes": { "defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"] }
        }
      },
      "ueId": "'$UEID'", "servingPlmnId": "20893", "singleNssai": { "sd": "112233", "sst": 1 }
    });
    ' > /dev/null 2>&1

    echo "  SUCCESS: Subscriber $UEID provisioned."
}

echo "Provisioning default subscriber..."
wait_mongo

add_subscriber "208930000000003" "8baf473f2f8fd09487cccbd7097c6862" "8e27b6af0e692e750f32667a3b14605d"
add_subscriber "208930000000004" "8baf473f2f8fd09487cccbd7097c6863" "8e27b6af0e692e750f32667a3b14605e"
