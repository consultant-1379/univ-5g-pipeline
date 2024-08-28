#! /bin/bash
# This script is copied from CCRC CPI

DAY0FILE=$1
PROFILE_DIR=$2

if [ -z $DAY0FILE ] || [ -z $PROFILE_DIR ]; then
  echo -e "excute cmd:\n"
  echo -e "$0 Day0File ProfilePath \n\n eg:\n"
  echo -e "$0 values.yaml Scripts/Deployment/profiles \n\n"
  exit -1
fi

enabled_profile=$(yq '.global.profiles[] | select (.enabled=="true") | path | .[-1]' $DAY0FILE)
merge_files=" "
for item in $enabled_profile; do
  merge_files+=$"$PROFILE_DIR/eric-ccrc-profile-$item.yaml"
  merge_files+=" "
done
merge_files+=$DAY0FILE
echo "merge_files are $merge_files"

newfile=${DAY0FILE%.*}.merged.yaml
yq eval-all '. as $item ireduce ({}; . * $item )' $merge_files > $newfile

printf "Congratulations! MERGE is successful.\n"
printf "Output file: $newfile\n"
