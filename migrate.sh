#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat << EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [--path-to-jenkins-properties] [--path-to-service-parameters] [--skip-migrating-environment-variable] [[--git-lab-access-token]] [[--git-lab-environment-variable-project-id]]

Script description here.

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--path-to-jenkins-properties    The complete path to Jenkinsfile.properties in project.
--path-to-service-parameters    Path to folder that contains parameter json files.
--skip-migrating-environment-variable   Skip migrating environment variable from Gitlab. Allowed values: true / false.
--git-lab-access-token  Access token generated from Gitlab.
--git-lab-environment-variable-project-id   The project id (repository) in Gitlab that contains environment variables.
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 message: "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
    # default values of variables set from params

    path_to_jenkins_properties=''
    path_to_service_parameters=''
    git_lab_access_token=''
    skip_migrating_environment_variable=false
    git_lab_environment_variable_project_id=0
    values_file_destination_path='infra'

    while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --path-to-jenkins-properties)
        path_to_jenkins_properties="${2-}"
        shift
        ;;
    --path-to-service-parameters)
        path_to_service_parameters="${2-}"
        shift
        ;;
    --git-lab-access-token)
        git_lab_access_token="${2-}"
        shift
        ;;
    --values-file-destination-path)
        values_file_destination_path="${2-}"
        shift
        ;;
    --skip-migrating-environment-variable)
        skip_migrating_environment_variable="${2-}"
        shift
        ;;
    --git-lab-environment-variable-project-id)
        git_lab_environment_variable_project_id="${2-}"
        shift
        ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
    done

  # check required params and arguments
  [[ -z "${path_to_jenkins_properties-}" ]] && die "Missing required parameter: path-to-jenkins-properties"
  [[ -z "${path_to_service_parameters-}" ]] && die "Missing required parameter: path-to-service-parameters"
  if [[ $skip_migrating_environment_variable = false ]]
  then
    [[ -z "${git_lab_access_token-}" ]] && die "Missing required parameter: git-lab-access-token"
    [[ -z "${git_lab_environment_variable_project_id-}" ]] && die "Missing required parameter: git-lab-environment-variable-project-id"
  fi

  return 0
}

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"    # You can either set a return variable (FASTER)
  REPLY="${encoded}"   #+or echo the result (EASIER)... or both... :p
}

parse_params "$@"
setup_colors


AWS_RESPONSE=$(aws sts get-caller-identity)
if [ -z "$AWS_RESPONSE" ]; then
    die "${RED}You have to be logged in on your AWS sandbox account. Run ${BLUE}okta-aws sandbox${NOFORMAT}${RED} and the rerun the script."
else
    if [[ $(jq -r '.Account' <<< $AWS_RESPONSE) != "616571706735" ]]
    then
        die "${RED}It seems you are not logged in using AWS's sandbox account.${NOFORMAT}"
    fi
fi

# script starts here
msg "${BLUE}Reading parameters:${NOFORMAT}"
msg "- path-to-jenkins-properties: ${path_to_jenkins_properties}"
msg "- path-to-service-parameters: ${path_to_service_parameters}"
msg "- git_lab_access_token: ${git_lab_access_token}"
msg "- git_lab_environment_variable_project_id: ${git_lab_environment_variable_project_id}"

curl --header "PRIVATE-TOKEN: ${git_lab_access_token}" "https://gitlab.aofl.com/api/v4/projects/2939/repository/files/$(rawurlencode 'Jenkinsfile')/raw?ref=master" > Jenkinsfile.original

if ! diff -q Jenkinsfile Jenkinsfile.original &>/dev/null; then
  >&2
    msg """${RED}The Jenkinsfile in this project is different than the original format.
     It is suggested to review these changes before going further with the migration process to make sure
     any custom or non-standard CI/CD process is migrated.${NOFORMAT}"""
    read -u 2 -p "Would you like to preview the diff? (y/n)" yn
    case $yn in
        [Yy]* )
            diff --old-group-format=$'\e[0;32m%<\e[0m' \
                --new-group-format=$'\e[0;31m%>\e[0m' \
                Jenkinsfile Jenkinsfile.original | tee diff.output && echo $diff.output; break;;
        [Nn]* )
            msg "${GREEN}It's up to you, we are just trying to help!${NOFORMAT}"; break;;
        * ) echo "Please answer yes or no.";;
    esac

    read -u 2 -p "Would you like to continue with the migration? (y/n)" yn
    case $yn in
        [Yy]* )
            msg "${YELLOW}Proceeding with migration...${NOFORMAT}" ; break ;;
        [Nn]* )
            rm Jenkinsfile.original diff.output && die "Terminating migration script!"; break ;;
        * ) echo "Please answer yes or no.";;
    esac
fi

rm -f Jenkinsfile.original diff.output

while read LINE; do export "JENKINS_PROPERTIES_${LINE}"; done < $(pwd)/${path_to_jenkins_properties}

for ENVIRONMENT in dev stage prod
do
    msg "${YELLOW}*****************************************${NOFORMAT}"
	ENVIRONMENT_UPPER_CASE=$(echo ${ENVIRONMENT} | tr '[:lower:]' '[:upper:]')
    msg "${GREEN}Migrating ${ENVIRONMENT_UPPER_CASE} environment now!${NOFORMAT}"
    msg "${YELLOW}*****************************************${NOFORMAT}"

    AWS_CFN_ENV_NAME_VAR="JENKINS_PROPERTIES_${ENVIRONMENT_UPPER_CASE}_AWS_CFN_ENV_NAME"
    STACK_NAME="${!AWS_CFN_ENV_NAME_VAR}-$JENKINS_PROPERTIES_DEPLOYMENT_TYPE-$JENKINS_PROPERTIES_APPLICATION_NAME"
    REGION_VAR="JENKINS_PROPERTIES_${ENVIRONMENT_UPPER_CASE}_AWS_DEFAULT_REGION"

    TEMPLATE_PARAMETERS=$(jq -r 'to_entries | map("  \(.value.ParameterKey): \"\(.value.ParameterValue|tostring)\"")|.[]' ${path_to_service_parameters}/parameters-$ENVIRONMENT.json)
    ENVIRONMENT_PATH=$(jq -r '.[] | select(.ParameterKey=="ContainerEnvPath") | .ParameterValue' ${path_to_service_parameters}/parameters-$ENVIRONMENT.json)
    AWS_PROFILE=$(jq -r '.[] | select(.ParameterKey=="AwsCfnEnvironmentName") | .ParameterValue' ${path_to_service_parameters}/parameters-$ENVIRONMENT.json)

    PUBLIC_ENVIRONMENT_VARIABLES=""
    PRIVATE_ENVIRONMENT_VARIABLES=""

    if [[ $skip_migrating_environment_variable = false ]]
    then

        PROJECT_INFO=$( curl --silent --header "PRIVATE-TOKEN: ${git_lab_access_token}" "https://gitlab.aofl.com/api/v4/projects/${git_lab_environment_variable_project_id}")

        if [[ $(jq -r '.message' <<< $PROJECT_INFO) = "404 Project Not Found" ]]
        then
            die "${RED}The gitlab_project id provided does not exist."
        fi

        if [[ $(jq -r '.message' <<< $PROJECT_INFO) = "401 Unauthorized" ]]
        then
            die "${RED}The gitlab token provided is not authorized to perform project listing."
        fi

        GITLAB_FOLDERS=$( curl --silent --header "PRIVATE-TOKEN: ${git_lab_access_token}" "https://gitlab.aofl.com/api/v4/projects/${git_lab_environment_variable_project_id}/repository/tree?recursive=true")

        msg "${ORANGE}Please select the file that has has environment variables for ${ENVIRONMENT_UPPER_CASE}: ${NOFORMAT}"
        choices=($(jq -r '.[] | select(.type=="blob" )  | select(.path | contains(".env") ) | .path' <<< $GITLAB_FOLDERS) "Skip migrating environment")

        ERROR_FLAG=false
        select environment_path in "${choices[@]}"; do
          for item in "${choices[@]}"; do
            if [[ $item == $environment_path ]]; then
                break 2
            else
                ERROR_FLAG=true
            fi
          done
          if [[ ${ERROR_FLAG} ]]
          then
              msg "${RED}Wrong option, please select a valid option.${NOFORMAT}"
          fi
        done

        if [[ "${environment_path}" != "Skip migrating environment" ]]
        then
            ENVIRONMENT_FILE_CONTENT=$( curl --silent --header "PRIVATE-TOKEN: ${git_lab_access_token}" "https://gitlab.aofl.com/api/v4/projects/${git_lab_environment_variable_project_id}/repository/files/$(rawurlencode ${environment_path})/raw?ref=master")

            while IFS= read -r line
            do
                echo "${RED}$line${NOFORMAT}"
                while true; do
                    key_value=(${line//=/ })
                    read -u 2 -p "Is this considered a secret variable? (y/n)" yn
                    case $yn in
                        [Yy]* )
                            PRIVATE_ENVIRONMENT_VARIABLES+="${key_value[0]}: ${key_value[1]} \n"; break;;
                        [Nn]* ) PUBLIC_ENVIRONMENT_VARIABLES+="  ${key_value[0]}: ${key_value[1]}\n"; break;;
                        * ) echo "Please answer yes or no.";;
                    esac
                done
            done <<< "$ENVIRONMENT_FILE_CONTENT"
        fi
    fi

    if [[ ! -z ${PRIVATE_ENVIRONMENT_VARIABLES} ]]
    then
        echo "${PRIVATE_ENVIRONMENT_VARIABLES}" > ${values_file_destination_path}/secrets.$ENVIRONMENT.yaml
        sops --kms arn:aws:kms:us-west-2:616571706735:key/88e4bfca-9a13-4968-a6ce-07ffa90794d6 -i -e ${values_file_destination_path}/secrets.$ENVIRONMENT.yaml
    fi

echo '''stackName: '$STACK_NAME'
region: '${!REGION_VAR}'
templateFilePath: '${values_file_destination_path}'/template.yaml
capabilities: CAPABILITY_NAMED_IAM ''' > ${values_file_destination_path}/values.$ENVIRONMENT.yaml
if [[ ! -z ${PRIVATE_ENVIRONMENT_VARIABLES} ]]
then
    echo "secretsFilePath: ${values_file_destination_path}/secrets.${ENVIRONMENT}.yaml" >> ${values_file_destination_path}/values.$ENVIRONMENT.yaml
fi
echo '''cfnTemplateParameters:
'"${TEMPLATE_PARAMETERS}"'
environmentVariables:
'${PUBLIC_ENVIRONMENT_VARIABLES}'
''' >> ${values_file_destination_path}/values.$ENVIRONMENT.yaml

done

while true; do
    msg """${PURPLE}After migrating to Gitlab, there are some files related to Jenkins are not needed.
    Here is a list of files not neede:
    1. Jenkinsfile
    2. Jenkinsfile.properties
    3. ${path_to_service_parameters}/parameters-dev.json
    4. ${path_to_service_parameters}/parameters-stage.json
    5. ${path_to_service_parameters}/parameters-prod.json
    ${NOFORMAT}"""
    read -u 2 -p "Would you like the migration script to take care of this? (y/n)" yn
    case $yn in
        [Yy]* )
            rm Old_Jenkinsfile &&
            rm Old_Jenkinsfile.properties &&
            rm ${path_to_service_parameters}/parameters-*.json &&
            msg "${GREEN}Jenkins related files were deleted!${NOFORMAT}"; break;;
        [Nn]* ) msg "${YELLOW}Keeping Jenkins related file as requested.${NOFORMAT}"; break;;
        * ) echo "Please answer yes or no.";;
    esac
done

while true; do
    msg ''''${PURPLE}'There are some updates that has to be done on
    Dockerfile.

    Here is an example of a clean version of how a Dockerfile should look like:'${NOFORMAT}'

    '${ORANGE}'
    ARG COMPOSER_ARGS=''

    FROM gitlab.aofl.com:5001/aofl-base-images/php-builder:1 as vendor
    COPY composer.json composer.json
    COPY composer.lock composer.lock
    RUN composer install $COMPOSER_ARGS

    FROM gitlab.aofl.com:5001/engineering-automation_tools/automation_images/aofl/php-app-v2-base-builder:7.3
    COPY ./src /home/app/src
    COPY --from=vendor /app/src/vendor /home/app/src/vendor
    USER www-data
    '${NOFORMAT}'

    '${CYAN}'Please copy or fix your Dockerfile accommodate the updates.'${NOFORMAT}'
    '''
    read -u 2 -p "Did you fix Dockerfile? (y/n)" yn
    case $yn in
        [Yy]* )
            msg "${GREEN}Awesome!!${NOFORMAT}"; break ;;
        [Nn]* )
            msg "${GREEN}It's up to you, we are just trying to help!${NOFORMAT}"; break;;
        * ) echo "Please answer yes or no.";;
    esac
done
