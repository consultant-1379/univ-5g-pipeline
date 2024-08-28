#!/bin/bash

readonly YANG_PASS="EricSson@12-34"

readonly CRD_NS="eric-crd-ns"
declare -a list_of_ns=("eric-ccpc" "eric-eda2" "eric-cces" "eric-ccdm" "eric-ccrc" "eric-ccsm")
[ -z "${IGNORE_NS_LIST}" ] && IGNORE_NS_LIST=
[ -z "${ALWAYS_REINSTALL}" ] && ALWAYS_REINSTALL=true
[ -z "${HEALTHCHECK}" ] && HEALTHCHECK=true
[ -z "${SITE_ID}" ] && SITE_ID=0
if [ $(find ./adapted_dir -name *SITE* | wc -l) -eq 0 ]; then SITE_ID=0; fi
[ -z "${DEPLOY_NS}" ] && DEPLOY_NS=
[ -z "${DRY_RUN}" ] && DRY_RUN=false
[ -z "${DEPLOYMENT_PROPERTIES}" ] && DEPLOYMENT_PROPERTIES=deployment.properties
[ -z "${CLEANUP_ONLY}" ] && CLEANUP_ONLY=false
[ -z "${TARGET_EVNFM}" ] && TARGET_EVNFM=

if ! [ -z ${DEPLOY_NS} ]; then
  IGNORE_NS_LIST="|eric-ccdm|eric-ccsm|eric-ccrc|eric-eda2|eric-cces|eric-ccpc"
  if [ ${DEPLOY_NS} != 'NONE' ]; then
    for NS in $(echo ${DEPLOY_NS} | tr ',' "\n"); do
      echo ${IGNORE_NS_LIST} | grep -q ${NS}
      if [ $? -ne 0 ]; then
        echo -e "[ERROR] Unknown or duplicate namespace provided: ${NS}\nPossible inputs:\neric-ccdm,eric-ccsm,eric-ccrc,eric-eda2,eric-cces,eric-ccpc"
        exit 1
      fi
      IGNORE_NS_LIST=$(echo ${IGNORE_NS_LIST} | sed "s/|${NS}//")
    done
  fi
fi

if [ ${DRY_RUN} == 'true' ]; then
  echo -e "\nUsing dry run! Products won't be deployed"
  DRY_RUN_FLAGS="--dry-run --debug >/dev/null"
  if ! [ -z ${TARGET_EVNFM} ]; then
    echo "TARGET_EVNFM variable set! This cannot be used in combination with DRY_RUN! Exit"
    exit 1
  fi
fi

. ./cluster_vars.tmp
. ./evnfmFunctions.sh

function sleepFunction() {
  SLEEP_TIME=$1
  [ -z ${SLEEP_TIME} ] && SLEEP_TIME=10
  echo "Waiting ${SLEEP_TIME} seconds"
  for i in $(seq 1 ${SLEEP_TIME}); do
    echo -n "."
    sleep 1
  done
  echo
}

function printMessage() {
  local message="$1"
  echo
  echo "******************************************"
  echo "******************************************"
  echo "[$(date)] ${message}"
  echo "******************************************"
  echo "******************************************"
}

function cleanupImages() {
  printMessage "Removing non-used images from nodes to free disk space"
  kubectl get cm -n jenkins-tools jenkins-key -o jsonpath="{.data.privateKey}" > privateKey 2>&1
  if [ $? -eq 0 ]; then
    chmod 600 privateKey
    CURRENT_CLUSTER=$(kubectl get ingress -n kube-system | grep -oE "(capo|ibd).*ericsson.se" -m1 | cut -d. -f1)
    DIRECTOR_IPS=$(kubectl get cm -n jenkins-tools jenkins-key -o jsonpath="{.data.clusterInfo}" | grep directorIp | cut -d: -f2- | grep -o "[\.:0-9]\+")
    for DIRECTOR_IP in ${DIRECTOR_IPS}; do
      if [ $(ssh -q -o StrictHostKeyChecking=no -i privateKey eccd@${DIRECTOR_IP} "hostname | grep -oE '(capo|ibd).*' | cut -d- -f1,2") == ${CURRENT_CLUSTER} ]; then
        break
      fi
    done
    kubectl get ds wa-for-pause-image -n default >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      echo "Creating wa-for-pause-image daemonset, to prevent removal of pause image"
      export SANDBOX_IMAGE=$(ssh -q -o StrictHostKeyChecking=no -i privateKey eccd@${DIRECTOR_IP} "grep sandbox_image /etc/containerd/config.toml" | cut -d'"' -f2)
      cat k8s-resources/daemonset-wa-for-pause-image.yaml | envsubst | kubectl apply -n default -f -
      sleepFunction 5
    fi
    ssh -q -o StrictHostKeyChecking=no -i privateKey eccd@${DIRECTOR_IP} "
      for NODE in \$(kubectl get node -o=wide | grep worker | awk '{print \$6}'); do
        ssh -q -o StrictHostKeyChecking=no eccd@\${NODE} 'sudo crictl rmi --prune' &
      done"
  else
    echo "[WARNING] jenkins-key configmap not found!"
  fi
}

function waitForCleanup() {
  deletion=false
  attmp=0
  max_attmp=15
  while [ "${attmp}" -le "${max_attmp}" ]; do
    echo "Checking deletion..."
    ns_delete_pending=$(kubectl get ns | grep Terminating | wc -l)
    pv_delete_pending=$(kubectl get pv --no-headers | grep -vE "monitoring|kube-system${IGNORE_NS_LIST}" | wc -l)
    KUBE_VOLUMES=$(kubectl get pv | grep -E "monitoring|kube-system${IGNORE_NS_LIST}" | awk '{print $1}' | tr '\n' '|')
    volumes_pending=$(kubectl get volumeattachments.storage.k8s.io --no-headers | grep -vE ${KUBE_VOLUMES:0:-1} | wc -l)
    if [[ "${ns_delete_pending}" > 0 || "${pv_delete_pending}" > 0 || "${volumes_pending}" > 0 ]]; then
      echo "Deletion process is still pending (${ns_delete_pending} NS, ${pv_delete_pending} PV, ${volumes_pending} VA)..."
      attmp=$(( ${attmp} + 1 ))
      sleepFunction 60
    else
      echo "Deletion process is finished!!"
      deletion=true
      break
    fi
  done
  if [ "${deletion}" == false ]; then
    echo "Deletion process failed!!"
    exit 1
  fi
  sleepFunction 60
}

function addNetworkPolicies () {
  export ns=$1
  for app in "${@:2}"; do
    export app
    cat ./k8s-resources/network_policy_template.yaml | envsubst | kubectl apply -n ${ns} -f -
  done
}

function addIstioResources () {
  ns=$1
  #Adding DR/SE for all TGs from coredns
  for TG_HOST in $(kubectl get cm -n kube-system coredns -o yaml | grep -v last-applied-configuration | grep "seliius\|pipeline" | grep -v ".see$" | awk '{print $2}'); do
    export TG_NAME=$(echo ${TG_HOST} | cut -d- -f1 | cut -d. -f1)
    export TG_HOST
    #Looking for yaml files ./k8s-resources/istio*
    #If "applicable-for" label in yaml contains current ns, create resource
    EXISTING_DR=$(kubectl get dr -n ${ns} -o yaml | grep -m1 "name:.*sbi" -A40 | grep -v apiVersion)
    export CA_CERT=$(echo "${EXISTING_DR}" | grep caCertificates -m1 | awk '{print $2}')
    export CLIENT_KEY=$(echo "${EXISTING_DR}" | grep privateKey -m1 | awk '{print $2}')
    export CLIENT_CRT=$(echo "${EXISTING_DR}" | grep clientCertificate -m1 | awk '{print $2}')
    for RES in $(grep -l "applicable-for.*${ns}" ./k8s-resources/istio*); do
      cat ${RES} | envsubst | kubectl apply -n ${ns} -f -
    done
  done
}

function createSecrets () {
    ns=$1
    kubectl get ns | grep -q "^${ns} " || kubectl create ns ${ns}
    #Looking for yaml files ./k8s-resources/secret*
    #If "applicable-for" label in yaml contains current ns, create secret
    for SECRET in $(grep -l "applicable-for.*${ns}" ./k8s-resources/secret*); do
      kubectl apply -f ${SECRET} -n ${ns}
      NAME=$(grep name: ${SECRET} | awk '{print $2}')
      kubectl -n ${ns} label secret ${NAME} release=${ns} --overwrite
    done
}

function cleanup() {
  printMessage "REMOVING PREVIOUS INSTALLATION..."
  for ns in ${list_of_ns[@]}; do
    echo
    if [[ ${IGNORE_NS_LIST} == *"${ns}"* ]]; then
      printMessage "Removal of ${ns} skipped!"
      continue
    fi
    if [ ${ALWAYS_REINSTALL} == "false" ]; then
      reinstall_needed=false
      for chart in $(cat charts_dir/${ns}/chart_install_order | sed 's/.tgz//g'); do
        helm list -n ${ns} 2>/dev/null | grep -q ${chart}
        if [ $? -ne 0 ]; then
          printMessage "Reinstallation of ${ns} needed due to different chart version!"
          reinstall_needed=true
          break
        fi
      done
      if [ $(kubectl get pod -n ${ns} --no-headers| grep -v '\([0-9]\{1,2\}\)/\1' | grep -v "Completed\|Evicted\|ContainerStatusUnknown\|eventexposure-cleanup-job" | wc -l) -gt 0 ]; then
        printMessage "Reinstallation of ${ns} needed due to faulty pods!"
        reinstall_needed=true
      fi
      if [ ${reinstall_needed} == "false" ]; then
        printMessage "Reinstallation of ${ns} NOT needed!"
        IGNORE_NS_LIST="${IGNORE_NS_LIST}|${ns}"
        continue
      fi
    fi
    printMessage "Removing resources of ${ns} namespace (following EST best practices)..."
    export EVNFM_HOST=$(kubectl get secrets -n ${ns} -o yaml | grep .dockerconfigjson: | awk '{print $2}' | base64 -d | jq . | grep -m1 registry.5g | cut -d'"' -f2 | sed 's/registry/evnfm/')
    if ! [ -z ${EVNFM_HOST} ]; then
      echo "Previous deployment was done using ${EVNFM_HOST}! Sending terminate to EVNFM"
      terminateVnf ${ns}
      if [ $? -ne 0 ]; then
        echo "Failed to terminate ${ns} on ${EVNFM_HOST}!"
      fi
    fi
    if ! [ -z ${TARGET_EVNFM} ]; then
      #terminate again, this time on target EVNFM, just in case some trash remained there
      #this is done because it's possible that previous installation was done using EVNFM A, and now we switch to EVNFM B
      export EVNFM_HOST=${TARGET_EVNFM}
      terminateVnf ${ns}
      if [ $? -ne 0 ]; then
        echo "Failed to terminate ${ns} on ${EVNFM_HOST}!"
        continue
      fi
    fi

    #proceed with these actions even if EVNFM is used, just in case something remained
    echo -e "\nScaling-in statefulsets..."
    kubectl get geodecluster -n ${ns} -o yaml | sed 's/\(locators:\|servers:\|adminMgrs:\).*/\1 0/' | kubectl apply -f -
    kubectl -n ${ns} scale sts --all --replicas=0
    sleepFunction 5

    echo -e "\nRemoving sts,deploy,ds,job,pod,service..."
    kubectl delete geodecluster --all -n ${ns} --wait=false
    kubectl delete sts,deploy,ds,job,pod,service --all -n ${ns} --wait=false
    local releases=$(helm list -A | grep ${ns} | grep -v crd | awk '{print $1}')
    for release in ${releases}; do
      echo -e "\nRemoving helm release ${release}"
      helm uninstall ${release} --namespace ${ns} --no-hooks
    done
    echo -e "\nRemoving PVCs..."
    kubectl delete pvc --all -n ${ns} --wait=false
    echo -e "\nRemoving resources not belonging to namespace..."
    kubectl delete clusterrole $(kubectl get clusterrole | grep ${ns} | awk '{print $1}') --wait=false
    kubectl delete clusterrolebinding $(kubectl get clusterrolebinding | grep ${ns} | awk '{print $1}') --wait=false
    kubectl delete mutatingwebhookconfigurations $(kubectl get mutatingwebhookconfigurations | grep ${ns} | awk '{print $1}') --wait=false
    kubectl delete validatingwebhookconfigurations $(kubectl get validatingwebhookconfigurations | grep ${ns} | awk '{print $1}') --wait=false
    max_attmp=10
    attmp=0
    echo -e "\nWaiting for PVs to disappear..."
    while [ "${attmp}" -le "${max_attmp}" ]; do
      if [ $(kubectl get pv | grep ${ns}/ | wc -l) -eq 0 ]; then
        break
      fi
      attmp=$(( attmp + 1 ))
      sleepFunction 30
    done
    echo -e "\nRemoving namespace..."
    kubectl delete ns ${ns} --wait=false
  done
  cleanupImages
}

function checking_crd() {
  printMessage "CHECKING/INSTALLING CRD..."

  #Fill lists of CRD versions (on cluster and new)
  new_crds_tgz=($(find ./charts_dir -name "*-crd*" | rev | cut -d/ -f1 | rev | sort --version-sort))
  crds_cluster_charts=($(helm list -A | grep crd | awk '{print $9}'))

  kubectl get ns | grep -q "^${CRD_NS} " || kubectl create ns "${CRD_NS}"
  new_crd_names=($(echo ${new_crds_tgz[@]} | tr ' ' '\n' | grep -o ".*-crd" | uniq))

  #Check new versions of CRDs
  for ((i=0; i<${#new_crd_names[@]}; i++)); do
    crd_cluster_chart=($(echo ${crds_cluster_charts[@]} | tr ' ' '\n' | grep ${new_crd_names[$i]}))
    crd_newest_chart=($(echo ${new_crds_tgz[@]} ${crd_cluster_chart} | sed 's/.tgz//g' | tr ' ' '\n' | grep ${new_crd_names[$i]} | sort --version-sort | tail -1))
    if [ "${crd_newest_chart}" == "${crd_cluster_chart}" ]; then
      echo "No need for CRD update " ${new_crd_names[$i]}
      echo "============================================"
    else
      echo "CRD should be updated " ${new_crd_names[$i]}
      echo "============================================"
      crd_newest_tgz=($(echo ${new_crds_tgz[@]} | tr ' ' '\n' | grep ${crd_newest_chart}))
      eval helm upgrade --install "${new_crd_names[$i]}" ./charts_dir/"${crd_newest_tgz}" --namespace "${CRD_NS}"
      if [ $? -ne 0 ]; then
        echo "Failed to deploy ${crd_newest_tgz}"
        exit 1
      fi
    fi
  done
  sleepFunction 5
  echo "******************************************"
  echo "******************************************"
}

function install_and_configure() {
  if [ ${DRY_RUN} == "false" ]; then
    #add labels which will be used by CCSM pods and FW pod. They must not end up on the same worker due to clash of SCTP module
    kubectl label node $(kubectl get node | grep worker | head -n-4 | awk '{print $1}') wa-label=linux-with-fw-pod --overwrite
    kubectl label node $(kubectl get node | grep worker | tail -n4 | awk '{print $1}') wa-label=linux-without-fw-pod --overwrite
  fi

  deployed_list_of_ns=()
  for ns in ${list_of_ns[@]}; do

    if [[ ${IGNORE_NS_LIST} == *"${ns}"* ]]; then
      printMessage "Installation of ${ns} skipped!"
      continue
    fi

    product_name=$(echo $ns | cut -d- -f2)
    declare -g status_${product_name}=true

    if [ ${DRY_RUN} == "false" ]; then
      printMessage "INSTALLATION OF SECRETS FOR: ${ns} ..."
      createSecrets ${ns}
    fi

    if [ ${SITE_ID} -ne 0 ] && ([ "$ns" == "eric-ccdm" ] || ([ "$ns" == "eric-ccrc" ] && ! [ -z ${ccrc_nrf_sig_VIP_2} ])); then
      SITE_FILTER="SITE${SITE_ID}*"
    else
      SITE_FILTER=
    fi
    day0_file=$(find ./adapted_dir -name "adapted_${ns}*${SITE_FILTER}.yaml" | rev | cut -d/ -f1 | rev)

    printMessage "DEPLOYING PRODUCT CHARTS FOR: ${ns} ..."
    if [ -z ${TARGET_EVNFM} ]; then
      if ! [ -f ./charts_dir/${ns}/chart_install_order ]; then
        echo "ERROR: chart_install_order file not found for ${ns}!"
        declare -g status_${product_name}=false
        continue
      fi

      for chart_tar in $(cat ./charts_dir/${ns}/chart_install_order); do
        printMessage "Installing ${chart_tar}..."
        EXTRA_FLAGS="${DRY_RUN_FLAGS}"
        if [ -f ./charts_dir/${ns}/${chart_tar/tgz/yaml} ]; then
          EXTRA_FLAGS+=" -f ./charts_dir/${ns}/${chart_tar/tgz/yaml}"
        fi
        chart_name=$(echo ${chart_tar} | sed -e 's/-[0-9]\+\..*tgz//' -e 's/eric-act-cna/eric-eda2/')
        eval helm upgrade --install "$chart_name" ./charts_dir/${ns}/${chart_tar} -f ./adapted_dir/"${day0_file}" --namespace "${ns}" --timeout 1800s ${EXTRA_FLAGS}
        if [ $? -ne 0 ]; then
          echo "Failed to deploy ${chart_tar} chart."
          declare -g status_${product_name}=false
          continue 2
        fi
      done
    else
      if ! [ -f ./charts_dir/${ns}/package_id ]; then
        echo "ERROR: package_id file not found for ${ns}!"
        declare -g status_${product_name}=false
        continue
      fi
      export EVNFM_HOST=${TARGET_EVNFM}
      instantiateVnf ${ns} $(cat ./charts_dir/${ns}/package_id) ./adapted_dir/"${day0_file}"
      if [ $? -ne 0 ]; then
        echo "Failed to deploy ${ns}!"
        declare -g status_${product_name}=false
        continue
      fi
    fi

    if [ ${DRY_RUN} == "true" ]; then
      printMessage "Dry run enabled! Skipping configuration..."
      continue
    fi

    if [ "${ns}" == "eric-eda2" ]; then
      kubectl patch secret eric-act-client-certificate \
        --patch '{"data":{"mykeystore_fqdn.p12": "'$(base64 -w 0 < "configurations/EDA2/mykeystore_fqdn.p12")'"}}' --namespace "$ns"
      kubectl patch secret eric-act-client-certificate \
        --patch '{"data":{"eda2-clientkey.pem": "'$(base64 -w 0 < "configurations/EDA2/eda2-clientkey.pem")'"}}' --namespace "$ns"
      kubectl patch secret eric-act-client-certificate \
        --patch '{"data":{"eda2-cacert.pem": "'$(base64 -w 0 < "configurations/EDA2/eda2-cacert.pem")'"}}' --namespace "$ns"
      kubectl patch cm eric-act-activation-engine-notification-rules \
        --patch "{\"data\":{\"NotificationRulesEps.xml\": \"$(cat adapted_dir/eda2_helper__HSSEPC* | tr -d '\n' | sed 's/"/\\\"/g')\"}}" --namespace "$ns"
      kubectl patch cm eric-act-activation-engine-notification-rules \
        --patch "{\"data\":{\"NotificationRulesIms.xml\": \"$(cat adapted_dir/eda2_helper__HSSIMS* | tr -d '\n' | sed 's/"/\\\"/g')\"}}" --namespace "$ns"
      kubectl patch secret eric-act-cna-oam-secret \
        --patch '{"data":{"tls.crt": "'$(base64 -w 0 < "configurations/EDA2/eda2-server_crt.pem")'",
                          "tls.key": "'$(base64 -w 0 < "configurations/EDA2/eda2-server_key.pem")'"}}' --namespace "$ns"
      kubectl delete pod -lapp=eric-act-activation-engine --namespace "$ns" --wait=false

      if ! [ -z ${TARGET_EVNFM} ]; then
        #validator images are not present in EVNFM, set image location to armdocker
        VALIDATOR_IMAGE=$(grep eric-act-hss-validator adapted_dir/adapted_eric-eda2* -A1 | grep imageName | awk '{print $2}')
        kubectl get deploy -n ${ns} eric-act-activation-engine -o yaml | sed "s/\(image: \)[^/]*\(\/.*${VALIDATOR_IMAGE}:.*\)/\1armdocker.rnd.ericsson.se\2/" | kubectl apply -f -
        kubectl get sts -n ${ns} eric-act-activation-cli -o yaml | sed "s/\(image: \)[^/]*\(\/.*${VALIDATOR_IMAGE}:.*\)/\1armdocker.rnd.ericsson.se\2/" | kubectl apply -f -
        kubectl delete pod -n ${ns} -lapp=eric-act-activation-cli
      fi
    fi

    printMessage "CONFIGURATION OF: $ns ..."

    if [ "$ns" != "eric-eda2" ]; then
      KCUSERNAME="sysadmin"
      KCPASSWORD="ericsson"

      if [ "$ns" = "eric-ccdm" ]; then
        if [ ${SITE_ID} -eq 2 ]; then
          YANG_IP=${ccdm_oam_VIP_2}
        else
          YANG_IP=${ccdm_oam_VIP}
        fi
      elif [ "$ns" = "eric-ccsm" ]; then
        YANG_IP=${ccsm_oam_VIP}
      elif [ "$ns" = "eric-ccrc" ]; then
        if ! [ -z ${ccrc_nrf_sig_VIP_2} ] && [ ${SITE_ID} -eq 2 ]; then
          YANG_IP=${ccrc_oam_VIP_2}
        else
          YANG_IP=${ccrc_oam_VIP}
        fi
      elif [ "$ns" = "eric-cces" ]; then
        YANG_IP=${cces_oam_VIP}
      elif [ "$ns" = "eric-ccpc" ]; then
        YANG_IP=${ccpc_oam_VIP}
      else
        echo "Wrong namespace!!!"
      fi

      SSH_ASKPASS_SCRIPT=/tmp/ssh-askpass-script
      cat > "${SSH_ASKPASS_SCRIPT}" <<EOL
#!/bin/bash
echo "${KCPASSWORD}"
EOL
      chmod 777 "${SSH_ASKPASS_SCRIPT}"
      export DISPLAY=:0
      export SSH_ASKPASS="${SSH_ASKPASS_SCRIPT}"

      printMessage "Create users"
      attempt_yp=0
      MAX_YP_ATTEMPTS=7
      while [ "${attempt_yp}" -le "${MAX_YP_ATTEMPTS}" ]; do
        sleepFunction 60
        kubectl get pod -n ${ns} | grep cm-yang
        YANG_OUTPUT=$(setsid ssh -o "ConnectTimeout=5" -o StrictHostKeyChecking=no -p 830 sysadmin@${YANG_IP} -s netconf < ./users/create_${ns}_users.xml)
        RESULT_CODE=$?
        CONF_ERROR=false
        echo "${YANG_OUTPUT}" | grep -q "<rpc-error>" && CONF_ERROR=true
        if [ "${RESULT_CODE}" -ne 0 ] || [ "${CONF_ERROR}" == 'true' ]; then
          echo "ERROR: Problem with creating users in $ns namespace!"
          echo "${YANG_OUTPUT}"
        else
          echo "Create users successfully in $ns namespace!"
          break
        fi
        attempt_yp=$(( ${attempt_yp} + 1 ))
      done
      if [ "${attempt_yp}" -gt "${MAX_YP_ATTEMPTS}" ]; then
        echo "FAILURE: Create user or users unsuccessfully"
        declare -g status_${product_name}=false
        continue
      fi

      printMessage "Changing users password for the first time login"
      sleepFunction 10
      export DISPLAY=:0
      export SSH_ASKPASS=/tmp/ssh-askpass-script
      setsid ./configurations/autoChangePwdUsers.sh "${YANG_IP}"

      printMessage "Put configuration to CM"
      cat > "${SSH_ASKPASS_SCRIPT}" <<EOL
#!/bin/bash
echo "${YANG_PASS}"
EOL

      if [ ${SITE_ID} -ne 0 ] && ([ "$ns" == "eric-ccdm" ] || ([ "$ns" == "eric-ccrc" ] && ! [ -z ${ccrc_nrf_sig_VIP_2} ])); then
        SITE_FILTER="SITE${SITE_ID}*"
      else
        SITE_FILTER=
      fi
      day1_file=($(find ./adapted_dir -name "adapted_${ns}*${SITE_FILTER}.xml" | sort))

      printMessage "Upload certificates and day-1 files for ${ns}"
      for file in ./configurations/certificates_all.xml ${day1_file[@]}; do
        echo "Uploading ${file} ..."
        echo
        attempt_yp_3=0
        MAX_YP_ATTEMPTS_3=20
        while [ "${attempt_yp_3}" -le "${MAX_YP_ATTEMPTS_3}" ]; do
          echo
          if [ ${file} == "./configurations/certificates_all.xml" ]; then
            USER="admin-sec-netconf"
          else
            USER="admin"
          fi
          YANG_OUTPUT=$(setsid ssh -o "ConnectTimeout=5" -o "StrictHostKeyChecking no" ${USER}@"${YANG_IP}" -p 830  -s netconf < "${file}")
          #check_young_output
          RESULT_CODE=$?
          echo "${YANG_OUTPUT}"
          CONF_ERROR=false
          echo "${YANG_OUTPUT}" | grep -q "<rpc-error>" && CONF_ERROR=true

          if [ "${RESULT_CODE}" -ne 0 ]; then
            echo "ERROR: Problem with connecting to YANG provider!"
          elif [ "${CONF_ERROR}" == 'true' ]; then
            echo "ERROR: Configuration loading returned errors!"
          else
            echo "Configuration loaded successfully"
            break
          fi
          echo
          sleepFunction 20
          attempt_yp_3=$(( ${attempt_yp_3} + 1 ))
        done
        if [ "${attempt_yp_3}" -gt "${MAX_YP_ATTEMPTS_3}" ]; then
          echo "FAILURE: Unable to load configuration for ${ns}"
          declare -g status_${product_name}=false
          continue 2
        fi
        echo
        echo
      done
    fi

    printMessage "Adding custom network policies for $ns"
    addNetworkPolicies $ns eric-pm-server eric-ctrl-bro eric-cm-mediator eric-data-search-engine
    if [ $ns == "eric-ccdm" ]; then
      addNetworkPolicies $ns eric-udr-system-status-provider
    elif [ $ns == "eric-ccrc" ]; then
      addNetworkPolicies $ns eric-nrf-provision
    fi

    printMessage "Adding custom ServiceEntry and DestinationRule for $ns"
    addIstioResources $ns

    if [ $ns == "eric-ccdm" ]; then
      echo "Restarting MAPI pods, to apply EDA2 certificates"
      kubectl rollout restart deployment -n $ns eric-act-mapi-provisioning
    fi

    if [ $ns == "eric-ccrc" ]; then
      echo "Restarting discovery agents to avoid missing NRF subscriptions (UDM5GP-73485)"
      for AGENT in $(kubectl get pod -A -lapp=eric-nrf-discovery-agent --no-headers | grep -v ccrc | awk '{print $1":"$2}'); do
        kubectl delete pod -n $(echo ${AGENT} | tr ':' ' ') --wait=false
      done
    fi

    status_variable="status_${product_name}"
    status_value=$(eval echo ${!status_variable})
    if [ ${status_value} == 'true' ]; then
      deployed_list_of_ns+=("$ns")
    fi
  done

  if [ ${DRY_RUN} == "true" ] && [[ "$status_ccdm" = 'false' || "$status_ccsm" = 'false' || "$status_ccrc" = 'false' || "$status_cces" = 'false' || "$status_ccpc" = 'false' || "$status_eda2" = 'false' ]]; then
    printMessage "ERROR: Dry run for some products failed! Please check the logs!"
    exit 1;
  fi
  rm -f *json *yaml
}

function pods_down() {
  namespace=$1
  echo
  printMessage "FAIL: some pods are not running in namespace ${namespace}:"
  podsDown=$(kubectl get pod -n "${namespace}" -o=wide --no-headers| grep -v '\([0-9]\{1,2\}\)/\1' | grep -v "Completed\|eventexposure-cleanup-job" | awk '{print $1}')
  for i in ${podsDown}
      do
          echo "********************************************"
          echo "Describe pod ${i}:"
          echo "********************************************"
          kubectl -n "${namespace}" describe pod $i
          for j in `kubectl --namespace "${namespace}" get pod $i -o jsonpath='{.spec.containers[*].name}'`
              do
                  echo "********************************************"
                  echo "Print log for $i container ${j}:"
                  echo "********************************************"
                  kubectl --namespace "${namespace}" logs $i -c $j
              done
      done
}

function waiting() {
  printMessage "Wait for pods to get up"

  # set dynamic status variable to false for every ns in list
  # e.g. status_ccpc=false

  for ns in ${deployed_list_of_ns[@]}; do
    declare -g status_$(echo $ns | cut -d- -f2)=false
  done

  num_of_namespaces=${#deployed_list_of_ns[@]}
  ok_namespaces=0
  attempt=0

  while [ "${attempt}" -lt 30 ]; do
    printMessage "ATTEMPT ${attempt}; STATUS: CCDM=${status_ccdm} CCSM=${status_ccsm} CCRC=${status_ccrc} CCES=${status_cces} CCPC=${status_ccpc} EDA2=${status_eda2}"
    if [ ${num_of_namespaces} -eq ${ok_namespaces} ]; then
      echo "INFO: All namespaces with passed installation are OK! Stoping checks"
      break
    elif [ "${attempt}" -ne 0 ]; then
      echo "WARNING: Some namespaces are not OK!"
      sleepFunction 60
    fi
    for ns in ${deployed_list_of_ns[@]}; do
      # check this namespace's status variable
      product_name=$(echo $ns | cut -d- -f2)
      status_variable="status_${product_name}"
      status_value=$(eval echo ${!status_variable})
      if [[ ${status_value} && ${status_value} = 'true' ]]; then
        continue
      else
        printMessage "Check if some pods are not running in namespace $ns "
        CHECK_PODS=$(kubectl get pod -n "${ns}" -o=wide --no-headers| grep -v '\([0-9]\{1,2\}\)/\1' | grep -v "Completed\|eventexposure-cleanup-job" | wc -l)
        curator_down=$(kubectl get pod -n "${ns}" -o=wide| grep eric-data-search-engine-curator | grep -v '\([0-9]\{1,2\}\)/\1'| grep -v "Completed\|eventexposure-cleanup-job" |  wc -l)
        if [[ "${CHECK_PODS}" > 0 && "${CHECK_PODS}" != ${curator_down} ]]; then
          echo
          echo "WARNING: some pods are not running:"
          kubectl get pod -n "${ns}" -o=wide | grep -v '\([0-9]\{1,2\}\)/\1' | grep -v "Completed\|eventexposure-cleanup-job"
          for POD in $(kubectl get pod -n ${ns} --no-headers | grep -v '\([0-9]\{1,2\}\)/\1' | grep -v "Completed\|eventexposure-cleanup-job" |awk '{print $1","$NF}');do
            AGE=$(echo ${POD} | cut -d, -f2 | grep -o "[0-9]\+m" | tr -d 'm')
            if ! [ -z ${AGE} ] && [ ${AGE} -ge 15 ]; then
              POD_NAME=$(echo ${POD} | cut -d, -f1)
              echo "[ERROR] ${POD_NAME} is running longer than 15 minutes, but it's not ready! Doing pod delete..."
              kubectl delete pod -n ${ns} ${POD_NAME} --wait=false
            fi
          done

        else
          echo "INFO: All PODs up and running in namespace $ns"

          printMessage "Checking the httpproxy status in $ns namespace"
          kubectl get httpproxy -n "${ns}"

          echo
          sleepFunction 5

          check_NRF_registrations ${ns}
          reg_ok=$?

          if [[ "$reg_ok" -eq 0 ]]; then
            echo "INFO: All NFs for $ns are registered in NRF"
            declare -g status_${product_name}=true
            ok_namespaces=$(( ${ok_namespaces} + 1))
          else
            echo "WARNING: Some NFs for $ns are not registered in NRF"
          fi

        fi
      fi
    done
    attempt=$(( ${attempt} + 1 ))
  done

  list_of_csars=($(echo "$(cat ${DEPLOYMENT_PROPERTIES} | grep "PACKAGES_VERSION" | awk -F '=' '{print $2}' | tr ',' " ")"))

  # check final status for all ns, prepare notif message
  for csar in ${list_of_csars[@]}; do
    for ns in ${list_of_ns[@]}; do
      if [ "$ns" == "eric-eda2" ]; then
        product_name="act"
      else
        product_name=$(echo ${ns} | cut -d- -f2 | tr '[:lower:]' '[:upper:]')
      fi
      if [[ "${csar}" == *${product_name}*  ]]; then
        csar_name=$(echo ${ns} | cut -d- -f2 | tr '[:lower:]' '[:upper:]')
        declare ${csar_name}_NOTIFY=${csar}
        product_name=$(echo $ns | cut -d- -f2)
        status_variable="status_${product_name}"
        status_value=$(eval echo ${!status_variable})
        # add final status to notif message
        if [[ ${status_value} && ${status_value} = 'false' ]]; then
          #pods_down ${ns}
          declare ${csar_name}_NOTIFY+=": FAILED"
        elif [[ ${status_value} && ${status_value} = 'true' ]]; then
          declare ${csar_name}_NOTIFY+=": SUCCEDED"
        else
          declare ${csar_name}_NOTIFY+=": SUCCEDED"
        fi
      fi
    done
  done

  printMessage "Prepare values for artifact"

  cat << EOF >> ${DEPLOYMENT_PROPERTIES}
CCDM=${CCDM_NOTIFY}
CCSM=${CCSM_NOTIFY}
CCRC=${CCRC_NOTIFY}
CCES=${CCES_NOTIFY}
CCPC=${CCPC_NOTIFY}
EDA2=${EDA2_NOTIFY}
EOF

  if [[ "$status_ccdm" = 'false' || "$status_ccsm" = 'false' || "$status_ccrc" = 'false' || "$status_cces" = 'false' || "$status_ccpc" = 'false' || "$status_eda2" = 'false' ]]; then
    printMessage "[ERROR] Exit due to faulty state of some product(s)!"
    exit 1;
  fi
  cleanupImages
}

function check_NRF_registrations() {
  ns=$1
  printMessage "Checking NRF registrations for $ns ..."
  list_of_NFs=()
  NF_FILTER="instances"

  if [[ ${HOSTNAME} == *"univ-deploy"* ]]; then
    echo "Setting certificates for curl command..."
    echo '--cert "/home/jenkins/agent/workspace/univ_deploy_products/auto_deploy_poc/configurations/EDA2/eda2-clientkey.pem" \
--cacert "/home/jenkins/agent/workspace/univ_deploy_products/auto_deploy_poc/configurations/EDA2/eda2-cacert.pem"' > $HOME/.curlrc
  fi

  if [ "$ns" = "eric-ccdm" ]; then
    list_of_NFs="UDR"
    if [ ${SITE_ID} -ne 0 ]; then
      NF_FILTER=$(cat adapted_dir/*SITE${SITE_ID}*udr* | grep "<nf-profile" -A200 | grep "</nf-profile" -B200 | grep instance-id | grep -v "\-dr" | cut -d">" -f2 | cut -d"<" -f1)
    fi
  elif [ "$ns" = "eric-ccsm" ]; then
    list_of_NFs=("UDM" "AUSF" "HSS" "5G_EIR")
  elif [ "$ns" = "eric-ccrc" ]; then
    list_of_NFs="NSSF"
    if ! [ -z ${ccrc_nrf_sig_VIP_2} ] && [ ${SITE_ID} -ne 0 ]; then
      NF_FILTER=$(cat adapted_dir/*SITE${SITE_ID}*nssf* | grep "<nf-profile" -A200 | grep "</nf-profile" -B200 | grep instance-id | grep -v "nssf" | cut -d">" -f2 | cut -d"<" -f1)
    fi
  elif [ "$ns" = "eric-cces" ]; then
    list_of_NFs="NEF"
  elif [ "$ns" = "eric-ccpc" ]; then
    list_of_NFs="PCF"
  else
    echo "WARNING: Wrong namespace or product don't have process of registration!!!!!"
  fi

  nfInstances=0
  for NF in ${list_of_NFs[@]}; do
    nfInstances=$(( ${nfInstances} + $(curl -s https://"${ccrc_nrf_sig_FQDN}":443/nnrf-nfm/v1/nf-instances?nf-type=${NF} | jq . | grep instances/ | grep ${NF_FILTER} | wc -l)))
  done

  if [ ${#list_of_NFs[@]} -le ${nfInstances} ]; then
    # number of registered NF instances is OK
    return 0
  else
    # number of registered NF instances is not OK
    return 1
  fi
}

main() {
  if [ ${DRY_RUN} == "false" ]; then
    cleanup
    waitForCleanup
  fi
  if [ ${CLEANUP_ONLY} == 'false' ]; then
    checking_crd
    install_and_configure
    if [ ${HEALTHCHECK} == "true" ] && [ ${DRY_RUN} == "false" ]; then
      waiting
    fi
  fi
}

main

