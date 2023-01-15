#!/usr/bin/env bash

# Based on https://github.com/actions/runner/blob/main/scripts/create-latest-svc.sh

set -e

fatal() {
  echo "$@" >&2
  exit 1
}

# Notes:
# PATS over envvars are more secure
# Downloads latest runner release (not pre-release)
# Configures it as a service more secure
# Should be used on VMs and not containers
# Works on OSX and Linux
# Assumes x64 arch
# See EXAMPLES below

flags_found=false

while getopts 's:g:n:r:u:l:df' opt; do
    flags_found=true

    case $opt in
    s)
        runner_scope=$OPTARG
        ;;
    g)
        ghe_hostname=$OPTARG
        ;;
    n)
        runner_name=$OPTARG
        ;;
    r)
        runner_group=$OPTARG
        ;;
    u)
        svc_user=$OPTARG
        ;;
    l)
        labels=$OPTARG
        ;;
    f)
        replace='true'
        ;;
    d)
        disableupdate='true'
        ;;
    *)
        echo "
Runner Service Installer
Examples:
RUNNER_CFG_PAT=<yourPAT> ./create-latest-svc.sh myuser/myrepo my.ghe.deployment.net
RUNNER_CFG_PAT=<yourPAT> ./create-latest-svc.sh -s myorg -u user_name -l label1,label2
Usage:
    export RUNNER_CFG_PAT=<yourPAT>
    ./create-latest-svc scope [ghe_domain] [name] [user] [labels]
    -s          required  scope: repo (:owner/:repo) or org (:organization)
    -g          optional  ghe_hostname: the fully qualified domain name of your GitHub Enterprise Server deployment
    -n          optional  name of the runner, defaults to hostname
    -r          optional  name of the runner group to add the runner to, defaults to the Default group
    -u          optional  user svc will run as, defaults to current
    -l          optional  list of labels (split by comma) applied on the runner
    -d          optional  allow runner to remain on the current version for one month after the release of a newer version
    -f          optional  replace any existing runner with the same name"
        exit 0
        ;;
    esac
done

shift "$((OPTIND - 1))"

if ! "$flags_found"; then
    runner_scope=${1}
    ghe_hostname=${2}
    runner_name=${3:-$(hostname)}
    svc_user=${4:-$USER}
    labels=${5}
    runner_group=${6}
fi

# apply defaults
runner_name=${runner_name:-$(hostname)}
svc_user=${svc_user:-$USER}

echo "Configuring runner @ ${runner_scope}"
sudo echo

#---------------------------------------
# Validate Environment
#---------------------------------------
runner_plat=linux
[ -n "$(which sw_vers)" ] && runner_plat=osx;

if [ -z "${runner_scope}" ]; then fatal "supply scope as argument 1"; fi
if [ -z "${RUNNER_CFG_PAT}" ]; then fatal "RUNNER_CFG_PAT must be set before calling"; fi

which curl || fatal "curl required.  Please install in PATH with apt-get, brew, etc"
which jq || fatal "jq required.  Please install in PATH with apt-get, brew, etc"

# bail early if there's already a runner there. also sudo early
if [ -d ./runner ]; then
    fatal "Runner already exists.  Use a different directory or delete ./runner"
fi

sudo -u "${svc_user}" mkdir runner

# TODO: validate not in a container
# TODO: validate systemd or osx svc installer

#--------------------------------------
# Get a config token
#--------------------------------------
echo
echo "Generating a registration token..."

base_api_url="https://api.github.com"
if [ -n "${ghe_hostname}" ]; then
    base_api_url="https://${ghe_hostname}/api/v3"
fi

# if the scope has a slash, it's a repo runner
orgs_or_repos="orgs"
if [[ "$runner_scope" == */* ]]; then
    orgs_or_repos="repos"
fi

RUNNER_TOKEN="$(curl -s -X POST "${base_api_url}/${orgs_or_repos}/${runner_scope}/actions/runners/registration-token" -H "accept: application/vnd.github.everest-preview+json" -H "authorization: token ${RUNNER_CFG_PAT}" | jq -r '.token')"
export RUNNER_TOKEN

if [ "null" == "$RUNNER_TOKEN" ] || [ -z "$RUNNER_TOKEN" ]; then fatal "Failed to get a token"; fi

#---------------------------------------
# Download latest released and extract
#---------------------------------------
echo
echo "Downloading latest runner ..."

arch=""
case "$(uname -m)" in
    x86_64)
        arch="x64"
        ;;
    aarch64)
        arch="arm64"
        ;;
    *)
        fatal "Unsupported architecture"
        ;;
esac

# For the GHES Alpha, download the runner from github.com
latest_version_label=$(curl -s -X GET 'https://api.github.com/repos/actions/runner/releases/latest' | jq -r '.tag_name')
latest_version="${latest_version_label:1}"
runner_file="actions-runner-${runner_plat}-${arch}-${latest_version}.tar.gz"

if [ -f "${runner_file}" ]; then
    echo "${runner_file} exists. skipping download."
else
    runner_url="https://github.com/actions/runner/releases/download/${latest_version_label}/${runner_file}"

    echo "Downloading ${latest_version_label} for ${runner_plat} ..."
    echo "$runner_url"

    curl -O -L "${runner_url}"
fi

ls -la ./*.tar.gz

#---------------------------------------------------
# extract to runner directory in this directory
#---------------------------------------------------
echo
echo "Extracting ${runner_file} to ./runner"

tar xzf "./${runner_file}" -C runner

# export of pass
sudo chown -R "$svc_user" ./runner

pushd ./runner

#---------------------------------------
# Unattend config
#---------------------------------------
runner_url="https://github.com/${runner_scope}"
if [ -n "${ghe_hostname}" ]; then
    runner_url="https://${ghe_hostname}/${runner_scope}"
fi

echo
echo "Configuring ${runner_name} @ $runner_url"
echo "./config.sh --unattended --url $runner_url --token *** --name $runner_name ${labels:+--labels $labels} ${runner_group:+--runnergroup \"$runner_group\"} ${disableupdate:+--disableupdate}"
sudo -E -u "${svc_user}" ./config.sh --unattended \
    --url "$runner_url" \
    --token "$RUNNER_TOKEN" \
    ${replace:+--replace} \
    --name "$runner_name" \
    ${labels:+--labels $labels} \
    ${runner_group:+--runnergroup "$runner_group"} \
    ${disableupdate:+--disableupdate} \
    --ephemeral

#---------------------------------------
# Run now!
#---------------------------------------
echo
echo "Starting runner ..."

waiting=0
timeout=3600
while IFS= read -t $timeout -r line; do
    echo "$line"
    if [[ "$line" == *"Listening for Jobs"* ]]; then
        timeout=5
        waiting=1
        continue
    fi
    waiting=0
    timeout=3600
done < <(sudo -E -u "${svc_user}" ./run.sh)

if [ $waiting -eq 1 ]; then
    fatal "Runner never picked up a job"
fi
