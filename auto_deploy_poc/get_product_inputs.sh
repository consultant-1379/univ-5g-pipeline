#!/bin/bash
############################################
#export variables before running the script
#otherwise default values will be used
if [ $(env | grep "^ARM_USER=\|^ARM_PASS=" | wc -l) -lt 2 ]; then
  echo "ARM credentials not set! Please export ARM_USER and ARM_PASS vars!"
  exit
fi
[ -z "${CCRC_REPO}" ] && CCRC_REPO=https://armdocker.rnd.ericsson.se/artifactory/proj-ccrc-helm-local/tmp/ccrc-csar
[ -z "${CCSM_REPO}" ] && CCSM_REPO=https://arm.seli.gic.ericsson.se/artifactory/proj-5g-ccsm-staging-generic-local/proj_ccsm/5g/csar
[ -z "${CCDM_REPO}" ] && CCDM_REPO=https://arm.seli.gic.ericsson.se/artifactory/proj-5g-ccdm-released-generic-local/CCDM
[ -z "${CCPC_REPO}" ] && CCPC_REPO=https://arm.seli.gic.ericsson.se/artifactory/proj-5g-ccpc-ci-internal-generic-local/ccpc-cle0
[ -z "${CCES_REPO}" ] && CCES_REPO=https://arm.seli.gic.ericsson.se/artifactory/proj-cces-dev-generic-local/csar/cces
[ -z "${EDA2_REPO}" ] && EDA2_REPO=https://arm.seli.gic.ericsson.se/artifactory/proj-activation-poc-helm-local/activation/verified
[ -z "${COLLECT_INPUTS}" ] && COLLECT_INPUTS=false
[ -z "${CCSM_USE_MASTER}" ] && CCSM_USE_MASTER=true
[ -z "${INPUT_DIR}" ] && INPUT_DIR=input_dir
[ -z "${CHARTS_DIR}" ] && CHARTS_DIR=charts_dir
[ -z "${FILES_FILTER}" ] && FILES_FILTER='ccrc-values.y\|nrf_conf.*temp\|nssf_c.*temp\|nrf-a.*temp\|udr_temp\|ccdm-val\|CCPC-val\|ccpc-nf-prof.*temp\|cna_day_0\|\/eric-cces-nef-mtls-smallmbb\|nef_conf.*temp\|\/eric-ccsm-values\|conf_common\|ausf_conf\|cm_adp_diameter\|cm_hss_\|cm_EPC_S.*_conf\|Notification_Config\|map_app\|udm_rem\|nef_diameter_conf_templat\|eir_conf\|hsm-arpf\|location_report\|ue_reachability_for\|loss_of_connectivity\|roaming_status\|supi_pei_change\|set_nfset_feature\|cm_nrf_agent_conf\|eric-cces-nef-mtls-2m\|Application_Counters'
############################################

. ./evnfmFunctions.sh

if [[ ${HOSTNAME} == *"univ-deploy"* ]]; then
  echo "Executing inside container! Temporary moving to this directory to avoid kill by k8s."
  WORKDIR=${PWD}
  mkdir -p /sys/fs/cgroup/tmp-dir-jenkins
  pushd /sys/fs/cgroup/tmp-dir-jenkins
fi

FILES_LIST=files_list.tmp
PRODUCT_REPOS=(${CCRC_REPO} ${CCSM_REPO} ${CCDM_REPO} ${CCPC_REPO} ${CCES_REPO} ${EDA2_REPO})
PACKAGE_LIST=()
rm -rf *tmp *csar ${INPUT_DIR} ${CHARTS_DIR} 2>/dev/null
mkdir -p ${INPUT_DIR} ${CHARTS_DIR}

DATE_CONVERT="s/\([0-9]\{2\}\)-\(.\{3\}\)-\([0-9]\{4\}\)/\1 \2 \3/"
for PRODUCT_REPO in ${PRODUCT_REPOS[@]}; do

  #EDA2
  if [[ ${PRODUCT_REPO} == *activation* ]]; then
    PATTERN="eric-act-cna-[\.0-9\-]\{5,12\}\.csar<"
  #CCPC - allowed x.y.z-b as well
  elif [[ ${PRODUCT_REPO} == *ccpc* ]]; then
    PATTERN="Ericsson\.CC..\.CXP[\.\+_0-9\-]\{12,25\}[\+_\-][0-9]\{1,3\}\.csar<"
  #CCSM,CCES,CCDM,CCRC
  else
    PATTERN="Ericsson\.CC..\.CXP[\+_0-9\-]\{12,25\}[\+_\-][0-9]\{1,3\}\.csar<"
  fi
  PACKAGE=
  echo "=================================="
  echo ${PRODUCT_REPO} | grep -i -o "cc..\|act\|hss" | tail -n1 | sed -e 's/act/EDA2/' -e 's/hss/CCSM/' | tr [:lower:] [:upper:]
  echo "=================================="
  echo "Processing ${PRODUCT_REPO}"
  if [[ ${PRODUCT_REPO} == *.csar ]]; then
    echo "Exact CSAR package provided as input!"
    COLLECT_INPUTS=true
    CSAR_URL=$(echo ${PRODUCT_REPO})

    PACKAGE_NAME=$(echo ${PRODUCT_REPO} | rev | cut -d/ -f1 | rev)
    PRODUCT_REPO=$(echo ${PRODUCT_REPO} | rev | cut -d/ -f2- | rev)
  else
    #when searching for version, first we take 10 latest packages (by date), and from them select package with highest revision number
    if [[ ${PRODUCT_REPO} == *ccsm* ]]; then
      if [ ${CCSM_USE_MASTER} == "true" ]; then
        PRODUCT_REPO=${PRODUCT_REPO}/master
      else
        DROP=$(curl -sS -k -L ${PRODUCT_REPO} -u${ARM_USER}:${ARM_PASS} | sed 's/<.*">//' | grep "drop[0-9]\{2\}" | \
          sed -e "${DATE_CONVERT}" | \
          sort -k4n -k3M -k2n | tail -n10 | sed -e 's/<\/a>//' | sort -k1,1 --version-sort | tail -n1 | awk '{print $1}')
        PRODUCT_REPO=${PRODUCT_REPO}/${DROP}
      fi
    fi
    PACKAGE=$(curl -sS -k -L ${PRODUCT_REPO} -u${ARM_USER}:${ARM_PASS} | sed 's/<.*">//' | \
      grep ${PATTERN} | sed -e "${DATE_CONVERT}" | \
      sort -k4n -k3M -k2n | tail -n10 | sed -e 's/<\/a>//' | sort -k1,1 --version-sort | tail -n1)
    PACKAGE_NAME=$(echo "${PACKAGE}" | awk '{print $1}')
  fi

  if [ -z ${PACKAGE_NAME} ]; then
    echo -e "[ERROR] PACKAGE NOT FOUND!\n"
    continue
  else
    SUBDIRECTORY=$(echo "${PACKAGE_NAME}" | tr [:upper:] [:lower:] | grep -o "cc..\|act" | sed -e 's/act/eda2/')
    mkdir -p ${CHARTS_DIR}/eric-${SUBDIRECTORY}
    echo -e "${PACKAGE}\n"
    PACKAGE_LIST+=(${PACKAGE_NAME})
    if [[ ${PRODUCT_REPO} == *http* ]]; then
      curl -k -u ${ARM_USER}:${ARM_PASS} ${PRODUCT_REPO}/${PACKAGE_NAME} -o ${PACKAGE_NAME}
      PACKAGE_PREFIX=""
    else
      PACKAGE_PREFIX="${PRODUCT_REPO}/"
    fi
    mkdir -p ${PACKAGE_NAME}.tmp
    #Untar CNCS folder in CCDM
    if [[ $(echo ${PRODUCT_REPO} | tr [:upper:] [:lower:]) == *ccdm* ]]; then
      unzip -o ${PACKAGE_PREFIX}${PACKAGE_NAME} Scripts/Deployment/eric-ccdm-tools*/* -d ccdm_tools > /dev/null
      if [ $? -ne 0 ]; then
        rm -fr ccdm_tools
      fi
    fi
    #Untar CNCS folder in CCPC
    if [[ $(echo ${PRODUCT_REPO} | tr [:upper:] [:lower:]) == *ccpc* ]]; then
      unzip -o ${PACKAGE_PREFIX}${PACKAGE_NAME} Scripts/Deployment/eric-ccpc-cncs-tools*/* -d ccpc_tools > /dev/null
      if [ $? -ne 0 ]; then
        rm -fr ccpc_tools
      fi
    fi
    #Untar profiles folder in CCRC
    if [[ $(echo ${PRODUCT_REPO} | tr [:upper:] [:lower:]) == *ccrc* ]]; then
      unzip -o ${PACKAGE_PREFIX}${PACKAGE_NAME} Scripts/Deployment/profiles/* -d ccrc_profiles_temp > /dev/null
      if [ $? -ne 0 ]; then
        rm -fr ccrc_profiles_temp
      fi
    fi
    unzip -o ${PACKAGE_PREFIX}${PACKAGE_NAME} Scripts/* -d ${PACKAGE_NAME}.tmp | grep inflating | awk '{print $2}' >> ${FILES_LIST}
    unzip -o ${PACKAGE_PREFIX}${PACKAGE_NAME} Definitions/* -d ${CHARTS_DIR}/eric-${SUBDIRECTORY} >/dev/null
    if ! [ -z ${TARGET_EVNFM} ]; then
      export EVNFM_HOST=${TARGET_EVNFM}
      onboardPackage ${PACKAGE_PREFIX}${PACKAGE_NAME}
      if [ $? -ne 0 ]; then
        echo "Failed to onboard ${PACKAGE_NAME}!"
        exit
      fi
    fi
    rm -f ${PACKAGE_NAME}
  fi

  echo -e "Moving charts to ${CHARTS_DIR}/eric-${SUBDIRECTORY}\n"
  VNFD=$(grep -l helm_packages: ${CHARTS_DIR}/eric-${SUBDIRECTORY}/Definitions/* 2>&1 | grep -v "Is a directory")
  grep "helm_package[0-9]*:" ${VNFD} -A3 | grep tgz | rev | cut -d/ -f1 | rev | uniq > ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order
  #packages might have custom chart instantiate order, not following chart ID (e.g. 4,1,2,3)
  ORDER=$(grep instantiate: -A30 ${VNFD} | grep get_artifact: -A30 | sed 's/change_package:\|terminate:\|scale:/other_op:/' \
    | grep -m1 "other_op:\|change_current_package:" -B30 | grep -o 'helm_package[0-9]' | grep -o '[0-9]')
  for NUM in ${ORDER}; do
    sed -n "${NUM}p" ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order >> ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order_sorted
  done
  if [ -f ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order_sorted ]; then
    mv ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order_sorted ${CHARTS_DIR}/eric-${SUBDIRECTORY}/chart_install_order
  fi

  grep "descriptor_id" -A2 -m1 ${VNFD} | grep -o "[0-9a-f]\{8\}-.*-[0-9a-f]\{12\}" > ${CHARTS_DIR}/eric-${SUBDIRECTORY}/package_id
  for CHART in $(find ${CHARTS_DIR}/eric-${SUBDIRECTORY} -name *tgz); do
    if [[ ${CHART} != *crd* ]]; then
      mv ${CHART} ${CHART/tgz/yaml} ${CHARTS_DIR}/eric-${SUBDIRECTORY} 2>/dev/null
    else
      mv ${CHART} ${CHARTS_DIR}
    fi
  done
  #Collect inputs for 5GC-Solution
  #################################
  if [[ ${COLLECT_INPUTS} == "true" ]]; then
    #EDA2
    if [[ ${CSAR_URL} == *activation* ]]; then
      PRODUCT_NAME="EDA"
    else
      PRODUCT_NAME=$(echo ${PACKAGE_NAME} | awk -F [.] '{print $2}')
    fi
    PRODUCT_YAML=$(find ${CHARTS_DIR}/eric-${SUBDIRECTORY}/Definitions -name "eric-${SUBDIRECTORY}-vnfd.yaml" -or -name "eric-${SUBDIRECTORY}-vnfd.yml" -or -name "eric-${SUBDIRECTORY}.yaml" -or -name "${PRODUCT_NAME}.yaml")
    REVISION=$(yq -r '.node_types.*.properties.software_version.default' < "${PRODUCT_YAML}")

    echo "${PRODUCT_NAME} ${CSAR_URL} ${REVISION}" >> artifact.txt
  fi
  ##################################
  rm -rf ${CHARTS_DIR}/eric-${SUBDIRECTORY}/Definitions
done

echo "=================================="
echo "Discarding not needed day-0/day-1 files"
sed -i "/${FILES_FILTER}/!d" ${FILES_LIST}
echo "=================================="
echo "Copying day-0/day-1 files to ${INPUT_DIR}"
for FILE_PATH in $(cat ${FILES_LIST}); do
  PREFIX=$(echo ${FILE_PATH} | grep -o "^eric-cc..\|^eric-act\|^Ericsson.CC.." | \
    sed -e 's/eric-act/eric-eda2/' -e 's/Ericsson./eric-/' | tr [:upper:] [:lower:])
  FILE_NAME=$(echo ${FILE_PATH}| rev | cut -d/ -f1 | rev)
  if [[ ${FILE_NAME} == *yaml ]]; then
    PREFIX=${PREFIX}_day0
  elif [[ ${FILE_NAME} == *xml ]]; then
    PREFIX=${PREFIX}_day1
  fi
  cp ${FILE_PATH} ${INPUT_DIR}/${PREFIX}__${FILE_NAME}
done

echo "=================================="
echo "List of CSAR packages:"
echo "${PACKAGE_LIST[*]}" | tr ' ' '\n'
echo "PACKAGES_VERSION=${PACKAGE_LIST[*]}" | tr ' ' ',' > deployment.properties

#Create JSON from artifact inputs
#################################
if [[ -f artifact.txt ]]; then
  JSON_STRING=$(
  jq -Rsc '[ split("\n")[] | select(length > 0) | split(" ") ] | {products:map({product_name: .[0], csar_url: .[1], revision: .[2]})}' artifact.txt
  )
  echo "PRODUCT_INPUTS=${JSON_STRING}" >> deployment.properties
fi
#################################

rm -rf *tmp 2>/dev/null

if [[ ${HOSTNAME} == *"univ-deploy"* ]]; then
  mv * ${WORKDIR}
  popd
  rmdir /sys/fs/cgroup/tmp-dir-jenkins
fi
