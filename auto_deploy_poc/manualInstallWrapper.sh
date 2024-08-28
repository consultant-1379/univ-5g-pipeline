#!/bin/bash
# RUN FROM TG!

##############################
echo "Checking if this machine is suitable for running scripts..."
for BINARY in kubectl helm unzip expect jq; do
  which ${BINARY} >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "${BINARY} not found! Exit..."
    exit 1
  fi
done

MIN_HELM_VER="v3.8.1"
MIN_KUBE_VER="v1.23.1"
HELM_VERSION=$(helm version --template='Version: {{.Version}}' | awk '{print $2}')
KUBE_VERSION=$(kubectl version -o json | jq -r '.clientVersion.gitVersion')

CHECK_HELM=$(echo -e "${MIN_HELM_VER}\n${HELM_VERSION}" | sort --version-sort | tail -n1)
CHECK_KUBE=$(echo -e "${MIN_KUBE_VER}\n${KUBE_VERSION}" | sort --version-sort | tail -n1)
if [ ${CHECK_HELM} != ${HELM_VERSION} ]; then
  echo "Helm version is ${HELM_VERSION}! Please upgrade the client to >= ${MIN_HELM_VER}"
  exit 1
fi
if [ ${CHECK_KUBE} != ${KUBE_VERSION} ]; then
  echo "Kubectl version is ${KUBE_VERSION}! Please upgrade the client to >= ${MIN_KUBE_VER}"
  exit 1
fi
##############################

LOG=install_log_$(date +"%d%m%Y-%H%M%S")

# ACTION: set path to admin.conf for first site
export KUBECONFIG=/path/to/site1/admin.conf

# OPTIONAL: set path to admin.conf for second site, in case of multi-cluster environments
#export SITE2_CONFIG=/path/to/site2/admin.conf

##### GET PRODUCT INPUTS #####

# ACTION: set package locations (filesystem or ARM location; drop83 example)
export CCRC_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/CCRC/eric-ccrc-CXP9037716_1.11.3-2.csar
export CCSM_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/CCSM/Ericsson.CCSM.CXP9037722_1_11_3_3.csar
export CCDM_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/CCDM/eric-ccdm-CXP9037622_1.10.11.csar
export CCES_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/CCES/Ericsson.CCES.CXP9037720_1_10_3_0.csar
export CCPC_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/CCPC/Ericsson.CCPC.CXP9037858_1_10_2.csar
export EDA2_REPO=/proj/udm_univ/5G_integration/CSAR_packages/drop83/EDA2/eric-act-cna-1.45.97.csar

bash ./get_product_inputs.sh | tee ${LOG}

##### ADAPT PRODUCTS #####
# WARNING: in case of multi-cluster environments (like WX), both KUBECONFIG and SITE2_CONFIG need to be defined!
# That's mandatory even if you deploy just one site, so all needed info can be collected!
bash ./adapt.sh | tee -a ${LOG}

##### INSTALL PRODUCTS #####
rm $HOME/.ssh/known_hosts     # this is removed to avoid key problems when loading day1
export ALWAYS_REINSTALL=true  # force reinstall, even if CCxx is on wanted version
export HEALTHCHECK=false      # avoid automatic healthcheck

export SITE_ID=1
# ACTION: set products you want to deploy (this example matches pod W)
export DEPLOY_NS="eric-ccsm,eric-ccdm,eric-eda2,eric-ccrc"
bash deploy_solution.sh | tee -a ${LOG}

# OPTIONAL: uncomment and set products for site 2 (example for pod X)
#export KUBECONFIG=${SITE2_CONFIG}
#export SITE_ID=2
#export DEPLOY_NS="eric-ccpc,eric-ccdm,eric-cces"
#bash deploy_solution.sh | tee -a ${LOG}

bash configureEda2.sh | tee -a ${LOG}
