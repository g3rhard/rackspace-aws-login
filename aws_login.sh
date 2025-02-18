# shellcheck shell=bash

#
# Determines the AWS credentials for return_code_aws_login specific account and exports them to the environment.
# In case return_code_aws_login Rackspace login is needed, enter the credentials in the browser window that opens. The cookies
# from Rackspace are stored in return_code_aws_login temporary file (encrypted with your Rackspace password) and used
# to avoid the login screen in the future.
#
# usage: source aws_login.sh
#        aws_login [aws_account_id]
#
function aws_login() {
  aws_account_no="$1";
  local config_dir="$HOME/.config/rackspace-aws-login"
  if [ ! -d "$config_dir" ]; then
    mkdir -p "$config_dir"
  fi

  local temporary_rackspace_token=""
  local rackspace_tennant_id
  local rackspace_username
  local rackspace_api_key

  function read_input() {
    if [ "${3:-}" = "hide_input" ]; then
      sensitive_value_flag="-s"
    else
      sensitive_value_flag=""
    fi

    # Git Bash does not have pgrep installed
    # shellcheck disable=SC2009
    if ps -p $$ | grep bash >/dev/null 2>&1; then
      # We reference the var to set via indirect reference + we explicitly want the flag to be interpreted by shell
      # shellcheck disable=SC2229,SC2086
      read -r $sensitive_value_flag -p "$1" "$2"
    elif ps -p $$ | grep zsh >/dev/null 2>&1; then
      # We reference the var to set via indirect reference + we explicitly want the flag to be interpreted by shell
      # shellcheck disable=SC2229,SC2086
      read -r $sensitive_value_flag "?$1" "$2"
    else
      echo "Please use bash or zsh."
      return 1
    fi

    return 0;
  }

  function get_aws_accounts_from_rackspace() {
    if [ -z "$temporary_rackspace_token" ]; then
      get_rackspace_token_and_tenant
    fi

    aws_accounts=$(curl --location 'https://accounts.api.manage.rackspace.com/v0/awsAccounts' \
      --silent \
      --header "X-Auth-Token: $temporary_rackspace_token" \
      --header "X-Tenant-Id: $rackspace_tennant_id" | jq -r '.awsAccounts[] | .awsAccountNumber + "_" + .name' | sed 's/\r//' | sort)

    echo "$aws_accounts" >"$config_dir/aws_accounts.txt"
  }

  function get_rackspace_username_and_api_key() {
    kpscript_executable=$(command -v kpscript)

    if [ -z "$KEEPASS_FILE" ] || [ -z "$kpscript_executable" ]; then
      # no Keepass in place --> ask the user
      echo "Did not found your Keepass file or KPScript executable. Please enter your Rackspace credentials."

      read_input 'Rackspace username: ' rackspace_username
      read_input 'Rackspace API key: ' rackspace_api_key "hide_input"

      echo ""
    else
      # get credentials from Keepass
      echo "Reading credentials from Keepass: $KEEPASS_FILE. Entry Rackspace (username + api-key field)."

      read_input 'Keepass Password: ' keepass_password "hide_input"
      echo ""

      # keepass_password is set via read_input, but indirectly
      # shellcheck disable=SC2154
      rackspace_username=$($kpscript_executable -c:GetEntryString "${KEEPASS_FILE}" -Field:UserName -ref-Title:"Rackspace" -FailIfNoEntry -pw:"$keepass_password" | head -n1)
      rackspace_api_key=$($kpscript_executable -c:GetEntryString "${KEEPASS_FILE}" -Field:api-key -ref-Title:"Rackspace" -FailIfNoEntry -pw:"$keepass_password" | head -n1)
    fi
  }

  function get_rackspace_token_and_tenant() {
    get_rackspace_username_and_api_key

    rackspace_token_json=$(curl --location 'https://identity.api.rackspacecloud.com/v2.0/tokens' \
      --header 'Content-Type: application/json' \
      --silent \
      --data "{
            \"auth\": {
                \"RAX-KSKEY:apiKeyCredentials\": {
                    \"username\": \"$rackspace_username\",
                    \"apiKey\": \"$rackspace_api_key\"
                }
            }
        }")

    temporary_rackspace_token=$(jq -r '.access.token.id' <<<"$rackspace_token_json")
    rackspace_tennant_id=$(jq -r '.access.token.tenant.id' <<<"$rackspace_token_json")
  }

  if [ ! -s "$config_dir/aws_accounts.txt" ]; then
    get_aws_accounts_from_rackspace
  fi

  # Git Bash does not have pgrep installed
  # shellcheck disable=SC2009
  if ps -p $$ | grep bash >/dev/null 2>&1; then
    aws_accounts=$(cat "$config_dir/aws_accounts.txt")
  elif ps -p $$ | grep zsh >/dev/null 2>&1; then
    # this is valid ZSH
    # shellcheck disable=SC2296
    aws_accounts=("${(@f)$(< "$config_dir/aws_accounts.txt")}")
  else
    echo "Please use bash or zsh."
    return 1
  fi

  if [ -n "$aws_account_no" ]; then
    aws_profile_name=""
    # false positive because of mixed bash and zsh code
    # shellcheck disable=SC2128
    for acc in $aws_accounts; do
      curr_aws_account_no=$(tr -dc '[:print:]' <<<"$acc" | cut -f 1 -d'_')
      if [ "$curr_aws_account_no" = "$aws_account_no" ]; then
        aws_profile_name=$(tr -dc '[:print:]' <<<"$acc" | cut -f 2- -d'_')
        break
      fi
    done

    if [ -z "$aws_profile_name" ]; then
      echo "Could not find profile name for account id: $aws_account_no"
      return 1
    fi
  else
    PS3='Select the AWS account to connect to: '
    # false positive because of mixed bash and zsh code
    # shellcheck disable=SC2128
    select opt in $aws_accounts; do
      aws_account_no=$(tr -dc '[:print:]' <<<"$opt" | cut -f 1 -d'_')
      aws_profile_name=$(tr -dc '[:print:]' <<<"$opt" | cut -f 2- -d'_')
      break
    done
  fi

  return_code_aws_login=0
  aws sts get-caller-identity --profile "$aws_profile_name" >/dev/null 2>&1 || return_code_aws_login=$?

  if [ $return_code_aws_login -ne 0 ]; then
    if [ -z "$temporary_rackspace_token" ]; then
      get_rackspace_token_and_tenant
    fi

    temp_credentials=$(curl --location --silent \
      --request POST "https://accounts.api.manage.rackspace.com/v0/awsAccounts/$aws_account_no/credentials" \
      --header "X-Auth-Token: $temporary_rackspace_token" \
      --header "X-Tenant-Id: $rackspace_tennant_id")

    access_key=$(jq -r '.credential.accessKeyId' <<<"$temp_credentials")
    secret_access_key=$(jq -r '.credential.secretAccessKey' <<<"$temp_credentials")
    session_token=$(jq -r '.credential.sessionToken' <<<"$temp_credentials")

    aws configure --profile "$aws_profile_name" set aws_access_key_id "$(echo "$access_key" | tr -d '\r\n')"
    aws configure --profile "$aws_profile_name" set aws_secret_access_key "$(echo "$secret_access_key" | tr -d '\r\n')"
    aws configure --profile "$aws_profile_name" set aws_session_token "$(echo "$session_token" | tr -d '\r\n')"
  else
    echo "The AWS credentials are still valid."
  fi

  echo "Switching the AWS_PROFILE to $aws_profile_name"

  export AWS_PROFILE="$aws_profile_name"

  return 0
}
