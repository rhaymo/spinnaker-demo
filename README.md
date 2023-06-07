# spinnaker-demo

## Objectives
Execute a canary release on gke cluster using only one versioned deployments.yml (every tutorial i have seen uses three deployments.yaml, for prod, baseline and canary). 
This lab  uses an helm chart

## How it works
This is the flow to deploy the helm chart using spinnaker
1. A tag is pushed on the git repo
2. The tag triggers a cloudbuild building two artifacts
    1. a docker image (identified by git revision id), pushed on container registry
    2. an helm chart pointing to the container, stored in a gcs bucket
3. To deploy the chart, the spinnaker pipeline is executed by command line, passing in the json pointing to the chart location in the bucket

## Working on
Spinnaker : 1.19.3
cloud-builders-helm: 3.7.0
helm: 3.9.3

Deployed java application is from
https://ordina-jworks.github.io/cloud/2018/06/01/Automated-Canary-Analysis-using-Spinnaker.html
https://github.com/andreasevers/spinnaker-demo

Proposed spinnaker pipelines are based on 
https://github.com/GoogleCloudPlatform/spinnaker-pipelines

## Configure environment
### Install Spinnaker on gcp from marketplace
### Install helm (skip on cloud shell)
```bash
wget https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
tar zxfv helm-v3.1.1-linux-amd64.tar.gz
cp linux-amd64/helm .
kubectl create clusterrolebinding user-admin-binding \
    --clusterrole=cluster-admin --user=$(gcloud config get-value account)
```
### Install istio
```bash
export GKE_CTX=gke_$PROJECT_ID_$ZONE_spinnaker-1
cd $HOME
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.10.2 sh -
cd $HOME/istio-1.10.2
export PATH=$PWD/bin:$PATH
istioctl install --set profile=demo \
    --set values.telemetry.enabled=true \
    --set values.telemetry.v2.enabled=true \
    --set values.telemetry.v2.stackdriver.enabled=true \
    --context ${GKE_CTX}
```

### Create gcs bucket
Create a gcs bucket named $PROJECT_ID-kubernetes-manifests/spinnaker-demo/charts
```bash
export PROJECT=$(gcloud info \
    --format='value(config.project)')
export BUCKET=$PROJECT-spinnaker-config
gsutil mb -c regional -l us-central1 gs://$BUCKET
gsutil mb -l $REGION gs://$PROJECT-kubernetes-manifests
```
create the folder spinnaker-demo/charts in the bucket 


### Create a cloud repo
```bash
gcloud source repos create sample-app
git config credential.helper gcloud.sh
git remote add origin https://source.developers.google.com/p/$PROJECT/r/spinnaker-demo
git push origin master
```

### Create a cloudbuild trigger on tags
In the Cloud Platform Console, click Navigation menu > Cloud Build > Triggers.
Click Create trigger.
Set the following trigger settings:
Name: spinnaker-demo-tags
Event: Push new tag
Select your newly created sample-app repository.
Tag: .*(any tag)
Configuration: Cloud Build configuration file (yaml or json)
Cloud Build configuration file location: /cloudbuild.yaml
Click CREATE.

### Create spinnaker pipelines
```bash
export APPLICATION=spinnakerdemo
./spin application save --application-name $APPLICATION \
                        --owner-email "$(gcloud config get-value core/account)" \
                        --cloud-providers kubernetes \
                        --gate-endpoint http://localhost:8080/gate
export PROJECT=$(gcloud info --format='value(config.project)')

sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/canary-config.json > updated-canary-config.json
spin canary canary-configs save --file updated-canary-config.json
export CANARY_CONFIG_ID=$(spin canary canary-configs list | jq '( .[] | select(.name == "Demo-config") | .id)')
echo $CANARY_CONFIG_ID

sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/prod-deploy.json > updated-prod-deploy.json
spin pipeline save --file updated-prod-deploy.json
export PROD_DEPLOY_PIPELINE_ID=$(spin pipeline get -a $APPLICATION -n 'Prod Deploy Pipeline' | jq -r '.id')
echo $PROD_DEPLOY_PIPELINE_ID

sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/restore-deploy.json > updated-restore-deploy.json
spin pipeline save --file updated-restore-deploy.json  
export RESTORE_DEPLOY_PIPELINE_ID=$(spin pipeline get -a $APPLICATION -n 'Restore Deployment' | jq -r '.id')
echo $RESTORE_DEPLOY_PIPELINE_ID

sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/baseline-deploy.json > updated-baseline-deploy.json
jq '(.stages[] | select(.refId == "2") | .pipeline) |= env.PROD_DEPLOY_PIPELINE_ID | (.stages[] |  select(.refId == "4") | .pipeline) |= env.PROD_DEPLOY_PIPELINE_ID' updated-baseline-deploy.json > updated-baseline-deploy.json
spin pipeline save --file updated-baseline-deploy.json
export BASELINE_DEPLOY_PIPELINE_ID=$(spin pipeline get -a $APPLICATION -n 'Deploy Baseline' | jq -r '.id')
echo $BASELINE_DEPLOY_PIPELINE_ID

sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/canary-deploy.json > updated-canary-deploy.json
jq '
(.stages[] | select(.refId == "19") | .pipeline) |= env.PROD_DEPLOY_PIPELINE_ID | \
(.stages[] | select(.refId == "23") | .pipeline) |= env.BASELINE_DEPLOY_PIPELINE_ID | \
(.stages[] | select(.refId == "13") | .pipeline) |= env.RESTORE_DEPLOY_PIPELINE_ID | \
(.stages[] | select(.refId == "17") | .pipeline) |= env.RESTORE_DEPLOY_PIPELINE_ID | \
(.stages[] | select(.refId == "25") | .pipeline) |= env.RESTORE_DEPLOY_PIPELINE_ID | \
(.stages[] | select(.refId == "10") | .canaryConfig.canaryConfigId) |= env.CANARY_CONFIG_ID | \
(.stages[] | select(.refId == "15") | .canaryConfig.canaryConfigId) |= env.CANARY_CONFIG_ID' \
updated-canary-deploy.json > updated-canary-deploy.json
spin pipeline save --file updated-canary-deploy.json
export CANARY_DEPLOY_PIPELINE_ID=$(spin pipeline get -a $APPLICATION -n 'Canary Deploy Pipeline' | jq -r '.id')
echo $CANARY_DEPLOY_PIPELINE_ID


sed -e 's/_APPNAME_/$APPLICATION/g' pipeline/trigger-deploy.json > updated-trigger-deploy.json
jq '(.stages[] | select(.refId == "4") | .pipeline) |= env.PROD_DEPLOY_PIPELINE_ID | (.stages[] |  select(.refId == "2") | .pipeline) |= env.CANARY_DEPLOY_PIPELINE_ID' updated-trigger-deploy.json > updated-trigger-deploy.json
spin pipeline save --file updated-trigger-deploy.json
export TRIGGER_DEPLOY_PIPELINE_ID=$(spin pipeline get -a $APPLICATION -n 'Trigger Deploy Pipeline' | jq -r '.id')
echo $TRIGGER_DEPLOY_PIPELINE_ID
```
## Launch a deploy
1. Modify the source code, tag and push it
```bash
git tag v1.0.0
git push --tags
```

2. Modify artifact.json to points to the helm chart you want deploy and launch the pipeline execution
```bash
spin pipeline execute --application canarytest --name "Trigger Deploy Pipeline" --artifacts-file ./artifact.json --parameter-file par.json
```

## Spinnaker pipelines description
* Prod Deploy Pipeline: deploy an helm chart (passed in as input), without canary test
* Deploy Baseline: get the helm chart deployed by 'Prod Deploy Pipeline' and deploy it using a single replica, using a different name for the deployment
* Restore Deployment: remove canary and baseline deployment, and restore all traffic to prod deployment
*  Canary Deploy Pipeline: deploy baseline (calling 'Deploy Baseline' pipeline), canary (passed in as input) and istio traffic control, and execute multiple canary test. It also call 'Restore Deployment' at the end of tests, and 'Prod Deploy Pipeline' in case of canary success
* Trigger Deploy Pipeline: starting point of the deploy, it receives an helm chart as input and calls 'Prod Deploy Pipeline' if there isn't a deployment, otherwise 'Canary Deploy Pipeline', passing to these pipelines the chart


## Improvements
Improve the handling of configmap, without define them in the pipelines


## Other useful commands
### Using gcs bucket as helm repository
In the above tutorial, the gcs bucket is not used as an helm repository, but simply as a folder. If you want to use it as an helm repository, configure it
```bash
helm gcs init gs://evolvere-iot-poc-kubernetes-manifests/spinnaker-demo/charts
```
You also have to configure cloudbuild using cloudbuild_for_helm_repository.yaml
This option is not tested, because spinnaker doesn't seem support helm repository on gcs bucket

### Spinnaker on gcp marketplace
If you have created the spinnaker instance using the gcp marketplace, halyard is not installed (it seems a bug). TO fix it, in scripts/cli/install_hal.sh modify:
```bash
sudo bash InstallHalyard.sh --user $USER -y $@
```
to
```bash
sudo bash InstallHalyard.sh  -y $@
```
