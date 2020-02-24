#!/bin/bash

SCRIPT_DIR=$(dirname $0)
DEMO_HOME=$SCRIPT_DIR/..


USER=$1
PASSWORD="$2"

if [ -z "$USER" ]; then
    echo "Must specify a user for registry.redhat.io"
    exit 1
fi

if [ -z "$PASSWORD" ]; then
    echo "Must specify a password for registry.redhat.io"
    exit 1
fi

echo "Using user: $USER and password: $PASSWORD"

# subscribe to AMQ Streams operator
oc apply -f $DEMO_HOME/kube/setup/redhat-operators-csc.yaml
oc apply -f $DEMO_HOME/kube/setup/subscription.yaml 

# FIXME: Wait for operator to be copied to the debezium-cdc project

# create a cluster in Debezium-cdc project
oc apply -f $DEMO_HOME/kube/kafka/kafka.yaml
oc apply -f $DEMO_HOME/kube/kafka/kafka-topic.yaml

# Create a secret for the registry the kafkaconnects2i depends on
# redhat.registry.io 
oc create secret docker-registry connects2i \
    --docker-server=registry.redhat.io \
    --docker-username="$USER" \
    --docker-password="$PASSWORD" \
    --docker-email=mhildenb@redhat.com

# wait until the cluster is deployed
# FIXME: my-cluster is assumed to be the name of the cluster for the demo
echo "Waiting up to 6 minutes for kafka cluster to be ready"
oc wait --for=condition=Ready kafka/my-cluster --timeout=360s
echo "Kafka cluster is ready."

# create an connect S2I cluster
oc apply -f $DEMO_HOME/kube/kafka/kafkaconnects2i-my-connect-cluster.yaml

# might have to wait to pull the image
sleep 5
# build config should appear immediately if it doesn't have trouble pulling the image

# build the connector
oc start-build my-connect-cluster-connect --from-dir=$DEMO_HOME/kube/kafka/connect-plugins --follow

# wait until the cluster is deployed
oc wait --for=condition=available dc/my-connect-cluster-connect

# expose the connect API service
oc expose svc my-connect-cluster-connect-api

# record the route
DBZ_CONNECTOR=$(oc get route my-connect-cluster-connect-api -o jsonpath='{.spec.host}')

# check the the service is up
echo "Checking that the connector is online:"
curl -H "Accept:application/json" $DBZ_CONNECTOR/
echo "\ndone."

# Configure the connector by calling through to its API
# The values therein are coming from values set from the previous script and yaml files
curl -X PUT -H "Content-Type: application/json" \
-d '{ 
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql", 
    "database.port": "3306", 
    "database.user": "root", 
    "database.password": "password", 
    "database.server.id": "184054",
    "database.server.name": "sampledb", 
    "database.whitelist": "sampledb",
    "database.history.kafka.bootstrap.servers": "my-cluster-kafka-bootstrap:9092", 
    "database.history.kafka.topic": "changes-topic",
    "decimal.handling.mode" : "double",
    "transforms": "route",
    "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.route.regex": "([^.]+)\\.([^.]+)\\.([^.]+)",
    "transforms.route.replacement": "$3"
}' \
    http://$DBZ_CONNECTOR/connectors/debezium-connector-mysql/config

echo "Checking that the mysql connector has been initialized:"
curl -H "Accept:application/json" $DBZ_CONNECTOR/connectors
echo "\ndone."