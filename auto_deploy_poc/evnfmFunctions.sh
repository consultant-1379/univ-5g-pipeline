#generic function to check if input parameters exist as env variables
#input: list of parameters
#return: RC0 if all of them exist. Otherwise RC1
function checkVars {
  VARS_OK=0
  for VAR in $@; do
    env | grep -q "^${VAR}="
    if [ $? -ne 0 ]; then
      VARS_OK=1
      echo "${VAR} variable not exported!"
    fi
  done
  return ${VARS_OK}
}

#get token from EVNFM
#input: EVNFM_USER EVNFM_PASS EVNFM_HOST env vars exported
#return: RC1 if failed. Otherwise TOKEN env var is exported
function getToken {
  checkVars EVNFM_USER EVNFM_PASS EVNFM_HOST || return 1
  TOKEN=$(curl -sS -k -X POST -H "Content-Type: application/json" -H "X-login: ${EVNFM_USER}" -H "X-password: ${EVNFM_PASS}" "https://${EVNFM_HOST}/auth/v1")
  echo ${TOKEN} | grep -q  "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}"
  if [ $? -ne 0 ]; then
    echo "Token couldn't be fetched! EVFNM response:"
    echo ${TOKEN}
    return 1
  else
    export TOKEN
  fi
}

#onboard cluster config to EVNFM
#input: EVNFM_HOST KUBECONFIG TOKEN env vars exported
function onboardCluster {
  getToken
  checkVars EVNFM_HOST KUBECONFIG TOKEN || return 1
  CLUSTER_NAME=$(grep server ${KUBECONFIG} | grep -o "udm[0-9]\+")
  cp ${KUBECONFIG} /tmp/${CLUSTER_NAME}.config

  CLUSTER_ID=$(curl -k -sS -X GET "https://${EVNFM_HOST}/vnflcm/v1/clusterconfigs?filter=(eq,name,${CLUSTER_NAME}.config)" -H "cookie:JSESSIONID=${TOKEN}"  | jq .items[].id)
  if [ -z ${CLUSTER_ID} ]; then
    echo "Loading ${CLUSTER_NAME} to ${EVNFM_HOST}"
    curl -k -sS -i --location -X POST https://${EVNFM_HOST}/vnflcm/v1/clusterconfigs \
      -F "clusterConfig=@/tmp/${CLUSTER_NAME}.config" \
      -H "cookie:JSESSIONID=${TOKEN}"
  else
    echo "${CLUSTER_NAME} already onboarded in ${EVNFM_HOST}! Skip onboard"
  fi
}

#onboard CSAR package to EVNFM, without checks
#input: @1=CSAR filename; EVNFM_HOST TOKEN env vars exported
#return: RC1 if failed, RC0 if OK
function onboardPackageInternal {
  checkVars EVNFM_HOST TOKEN || return 1
  CSAR_FILE=$1
  DESCRIPTION=$(echo ${CSAR_FILE} | rev | cut -d/ -f1 | cut -d. -f2- |rev)
  RESPONSE=$(curl -k -i --location -X POST https://${EVNFM_HOST}/vnfm/onboarding/api/vnfpkgm/v1/vnf_packages \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H "cookie:JSESSIONID=${TOKEN}" \
    -d "{\"userDefinedData\": {\"description\": \"${DESCRIPTION}\"}}" 2>&1)
  echo "${RESPONSE}" | grep HTTP/2 | grep -q 201
  if [ $? -ne 0 ]; then
    echo "Creating VNF package ID failed!"
    return 1
  else
    LOCATION=$(echo "${RESPONSE}" | grep location: | awk '{print $2}' | sed 's/\r//g')
    echo "Created VNF package ID: $(echo "${LOCATION}" | grep -o "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}")"
  fi

  echo "Onboarding ${CSAR_FILE}"
  RESPONSE=$(curl -k -sS -i --location -X PUT -H "cookie: JSESSIONID=${TOKEN}" -F "file=@${CSAR_FILE}" ${LOCATION}/package_content)
  echo "${RESPONSE}" | grep HTTP/2 | grep -q 202
  if [ $? -ne 0 ]; then
    echo "Onboarding failed!"
    curl -i -k -sS -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X DELETE ${LOCATION}
    return 1
  else
    echo "Onboarding started!"
  fi

  MAX_ATTEMPT=60
  ATTEMPT=0
  while [ ${ATTEMPT} -lt ${MAX_ATTEMPT} ]; do
    ATTEMPT=$(( ${ATTEMPT} +1 ))
    sleep 60
    if [ $(( ${ATTEMPT} % 20 )) -eq 0 ]; then getToken; fi
    STATE=$(curl -k -sS -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X GET ${LOCATION} | jq .onboardingState -r)
    if ! [ -z ${STATE} ] && [ ${STATE} == "ONBOARDED" ]; then
      echo "Onboarding finished successfully!"
      return 0
    elif ! [ -z ${STATE} ] && [ ${STATE} == "UPLOADING" ] || [ ${STATE} == "PROCESSING" ]; then
      echo "Onboarding still ongoing..."
    else
      echo "Something went wrong during onboarding! Last state:"
      curl -k -sS -i -v -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X GET ${LOCATION}
      curl -i -k -sS -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X DELETE ${LOCATION}
      return 1
    fi
  done
  echo "Onboarding didn't finish in expected time! Last state:"
  curl -k -sS -i -v -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X GET ${LOCATION}
  curl -i -k -sS -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -X DELETE ${LOCATION}
  return 1
}

#check if CSAR package exists in EVNFM, and call onboardPackageInternal
#input: @1=CSAR filename; EVNFM_HOST TOKEN env vars exported
#return: RC1 if failed, RC0 if OK
function onboardPackage {
  getToken
  checkVars EVNFM_HOST TOKEN || return 1
  CSAR_FILE=$1
  if [ -f "${CSAR_FILE}" ]; then
    echo ${CSAR_FILE} | grep -q "csar$"
    if [ $? -ne 0 ]; then
      echo "${CSAR_FILE} doesn't look like CSAR package!"
      return 1
    fi
  else
    echo "${CSAR_FILE} does not exist!"
    return 1
  fi
  echo -e "Processing ${CSAR_FILE}\nGetting CSAR package ID..."
  CSAR_PKG_ID=$(unzip -p ${CSAR_FILE} Definitions/*.y*ml | grep descriptor_id -A2 | grep -m1 -o "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}")
  CHECK_CSAR=$(curl -k -sS -H 'cookie: JSESSIONID='${TOKEN} -H 'Accept: application/json' \
    -X GET https://${EVNFM_HOST}/vnfm/onboarding/api/vnfpkgm/v1/vnf_packages \
    | jq -r '.[] | select(.vnfdId == "'${CSAR_PKG_ID}'") | .vnfdId')
  if [ -z ${CHECK_CSAR} ]; then
    echo "Package not onboarded to EVNFM! It will be done now (${CSAR_PKG_ID})"
    onboardPackageInternal ${CSAR_FILE}
  else
    echo "Package already onboarded to EVNFM (${CSAR_PKG_ID})!"
  fi
}

#call onboardCluster and instantiate package using EVNFM
#input: @1=namespace @2=CSAR ID @3=values YAML file; EVNFM_HOST TOKEN KUBECONFIG env vars exported
#return: RC1 if failed, RC0 if OK
function instantiateVnf {
  onboardCluster
  checkVars EVNFM_HOST TOKEN KUBECONFIG || return 1
  NS=$1
  PACKAGE_ID=$2
  VALUES=$3
  [ -z ${NS} ] && (echo "Namespace not specified!"; return 1)
  [ -z ${PACKAGE_ID=} ] && (echo "Package ID not specified!"; return 1)
  [ -z ${VALUES} ] && (echo "Values file not specified!"; return 1)

  CHECK_CSAR=$(curl -k -sS -H 'cookie: JSESSIONID='${TOKEN} -H 'Accept: application/json' \
    -X GET https://${EVNFM_HOST}/vnfm/onboarding/api/vnfpkgm/v1/vnf_packages \
    | jq -r '.[] | select(.vnfdId == "'${PACKAGE_ID}'") | .vnfdId')
  if [ -z ${CHECK_CSAR} ]; then
    echo "Package not onboarded to EVNFM (${PACKAGE_ID})"
    return 1
  fi

  PODS=$(kubectl get pod -n ${NS} --ignore-not-found |wc -l)
  if [ ${PODS} -ne 0 ]; then
    echo "Pods in ${NS} already exist! Please do the cleanup!"
    return 1
  fi

  CLUSTER_NAME=$(grep server ${KUBECONFIG} | grep -o "udm[0-9]\+")
  cat << EndPayload > ${NS}-info-vnf-${CLUSTER_NAME}.json
{
  "clusterName": "${CLUSTER_NAME}",
  "additionalParams": {
    "skipJobVerification": true,
    "skipVerification": true,
    "namespace": "${NS}",
    "helmNoHooks": false,
    "cleanUpResources": false,
    "applicationTimeOut": "3600",
    "disableOpenapiValidation": false,
    "helm_client_version": "3.8"
  }
}
EndPayload

  RESPONSE=$(curl -k -sS -i -X POST https://${EVNFM_HOST}/vnflcm/v1/vnf_instances \
    -H "cookie: JSESSIONID=${TOKEN}" -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "{\"vnfdId\": \"${PACKAGE_ID}\", \"vnfInstanceName\": \"${NS}-${CLUSTER_NAME}\"}")
  echo "${RESPONSE}" | grep HTTP/2 | grep -q 201
  if [ $? -ne 0 ]; then
    echo "Creating instance ID failed!"
    return 1
  else
    INSTANCE_ID=$(echo "${RESPONSE}" | grep -o '"id".*"vnfInstanceName"' | grep -o "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}")
    echo "Created instance ID: ${INSTANCE_ID}"
  fi

  RESPONSE=$(curl -sS -k -i -X POST https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID}/instantiate \
    -H 'cookie: JSESSIONID='${TOKEN} -H 'Content-Type: multipart/form-data' \
    -F "instantiateVnfRequest=@${NS}-info-vnf-${CLUSTER_NAME}.json" \
    -F "valuesFile=@${VALUES}")
  echo "${RESPONSE}" | grep HTTP/2 | grep -q 202
  if [ $? -ne 0 ]; then
    echo "Instantiation failed!"
    curl -i -k -sS  https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}" -X DELETE
    return 1
  else
    LOCATION_OP=$(echo "${RESPONSE}" | grep location: | awk '{print $2}' | sed 's/\r//g')
    echo "Instantiation started (${LOCATION_OP})"
  fi

  MAX_ATTEMPT=60
  ATTEMPT=0
  while [ ${ATTEMPT} -lt ${MAX_ATTEMPT} ]; do
    ATTEMPT=$(( ${ATTEMPT} +1 ))
    sleep 60
    if [ $(( ${ATTEMPT} % 20 )) -eq 0 ]; then getToken; fi
    OP_STATE=$(curl -k -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}" | jq .operationState -r)
    VNF_STATE=$(curl -k -sS  https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}" | jq .instantiationState -r)
    if ! [ -z ${OP_STATE} ] && ! [ -z ${VNF_STATE} ] && [ ${OP_STATE} == "COMPLETED" ] && [ ${VNF_STATE} == "INSTANTIATED" ]; then
      echo "Instantiation finished successfully!"
      return 0
    elif ! [ -z ${OP_STATE} ] && [ ${OP_STATE} == "PROCESSING" ]; then
      echo "Instantiation still ongoing..."
    else
      echo "Something went wrong during instantiation! Last state:"
      curl -k -i -v -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}"
      curl -k -i -v -sS https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}"
      return 1
    fi
  done
  echo "Instantiation didn't finish in expected time! Last state:"
  curl -k -i -v -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}"
  curl -k -i -v -sS https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}"
  return 1
}

#find VNF instance ID in EVNFM, based on cluster name and product name
#input: @1=product name; EVNFM_HOST TOKEN KUBECONFIG env vars exported
#return: instance ID
function getInstanceId {
  getToken
  checkVars EVNFM_HOST TOKEN KUBECONFIG || return 1
  CLUSTER_NAME=$(grep server ${KUBECONFIG} | grep -o "udm[0-9]\+")
  PRODUCT_NAME=$1

  #TODO: what if more of them?
  INSTANCE_ID=$(curl -k -sS "https://${EVNFM_HOST}/vnflcm/v1/vnf_instances?filter=(cont,vnfProductName,${PRODUCT_NAME});(eq,clusterName,${CLUSTER_NAME})" -H "cookie: JSESSIONID=${TOKEN}" | jq .[].id -r)

  echo ${INSTANCE_ID}
}

#call onboardCluster and terminate VNF using EVNFM
#input: @1=namespace; EVNFM_HOST TOKEN KUBECONFIG env vars exported
#return: RC1 if failed, RC0 if OK or instance ID not found
function terminateVnf {
  onboardCluster
  checkVars EVNFM_HOST TOKEN KUBECONFIG || return 1
  NS=$1
  [ -z ${NS} ] && (echo "Namespace not specified!"; return 1)
  PRODUCT_NAME=$(echo "${NS}" | grep -o "eda2\|cc.." | tr [:lower:] [:upper:] | sed 's/.*EDA2.*/Activation/')
  echo "Searching for instance id..."
  INSTANCE_ID=$(getInstanceId ${PRODUCT_NAME})
  if [ -z ${INSTANCE_ID} ] || [ ${INSTANCE_ID} == "null" ]; then
    echo "[WARNING] Instance ID not found in this EVNFM! Removal skipped"
    return 0
  fi
  STATE=$(curl -k -sS https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H cookie:JSESSIONID=${TOKEN} | jq .instantiationState -r)
  if ! [ -z ${STATE} ] && [ ${STATE} == "NOT_INSTANTIATED" ]; then
    RESPONSE=$(curl -i -k -sS -X DELETE https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H cookie:JSESSIONID=${TOKEN})
    echo "${RESPONSE}" | grep HTTP/2 | grep -q 204
    if [ $? -ne 0 ]; then
      echo "Removal of VNF ID ${INSTANCE_ID} failed!"
      return 1
    else
      echo "Removal of VNF ID ${INSTANCE_ID} OK!"
      return 0
    fi
  fi

  RESPONSE=$(curl -k -sS -i -X POST https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID}/terminate \
    -H 'Content-Type: application/json' -H cookie:JSESSIONID=${TOKEN} \
  -d '{
  "terminationType": "FORCEFUL",
  "additionalParams": {
    "cleanUpResources": true,
    "applicationTimeOut": "1800",
    "skipVerification": true,
    "skipJobVerification": true,
    "deleteIdentifier": true
  }}')

  echo "${RESPONSE}" | grep HTTP/2 | grep -q 202
  if [ $? -ne 0 ]; then
    echo "Termination failed!"
    return 1
  else
    LOCATION_OP=$(echo "${RESPONSE}" | grep location: | awk '{print $2}' | sed 's/\r//g')
    echo "Termination started (${LOCATION_OP})"
  fi

  MAX_ATTEMPT=60
  ATTEMPT=0
  while [ ${ATTEMPT} -lt ${MAX_ATTEMPT} ]; do
    ATTEMPT=$(( ${ATTEMPT} +1 ))
    sleep 60
    if [ $(( ${ATTEMPT} % 20 )) -eq 0 ]; then getToken; fi
    OP_STATE=$(curl -k -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}" | jq .operationState -r)
    VNF_STATE=$(curl -k -sS  https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}" | jq .instantiationState -r)
    if ! [ -z ${OP_STATE} ] && ! [ -z ${VNF_STATE} ] && [ ${OP_STATE} == "null" ] && [ ${VNF_STATE} == "null" ]; then
      echo "Termination finished successfully!"
      return 0
    elif ! [ -z ${OP_STATE} ] && [ ${OP_STATE} == "PROCESSING" ]; then
      echo "Termination still ongoing..."
    else
      echo "Something went wrong during termination! Last state:"
      curl -k -i -v -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}"
      curl -k -i -v -sS  https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}"
      return 1
    fi
  done
  echo "Termination didn't finish in expected time! Last state:"
  curl -k -i -v -sS ${LOCATION_OP} -H "cookie: JSESSIONID=${TOKEN}"
  curl -k -i -v -sS  https://${EVNFM_HOST}/vnflcm/v1/vnf_instances/${INSTANCE_ID} -H "cookie: JSESSIONID=${TOKEN}"
  return 1
}

#extract CSAR ID from package
#input: @1=CSAR filename
#return: CSAR ID
function getPackageId {
  unzip -p $1 Definitions/*.y*ml | grep descriptor_id -A2 | grep -m1 -o "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}"
}
