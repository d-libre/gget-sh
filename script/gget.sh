#!/usr/bin/env bash

# Exit on [e]rrors ([E]ven inside functions)
set -eE
# Globally export all [a]ssigned Env. Variable
set -a

declare -r __GGET_VERSION=0.1.0
declare -r __GGET_GITHUB_URL=https://github.com/d-libre/gget-sh

printf "gget v${__GGET_VERSION}\n"

source base 2>/dev/null || {
    printf "
    This script requires its |base| library to be installed along with it.\n
    Please read the installation notes first from
       ${__GGET_GITHUB_URL}#readme\n"
    exit 2
}

{ command -v curl && __GGET_WITH_CURL=1; } || { command -v wget && __GGET_WITH_WGET=1; } || {
    printf "
    This script requires you to have either curl or wget installed\n
    Please install any of them before\n"
    exit 3
}

declare -r __GGET_SCRIPT_LOCATION=$(base::where ${BASH_SOURCE[0]})

__showHelp() {
    # TODO: Tool to properly handle/render the markdown instead of just "cat" it
    cat ${__GGET_SCRIPT_LOCATION}/docs/gget.md 2>/dev/null || {
        printf "
Download Code directly from a public/private GitHub Repository

Usage:
    gget [OPTIONS] <github-user>/<repository> | <full-github-repository-url>
Please read ${__GGET_GITHUB_URL}#readme for more details

"
    }
}

echo ":: ${__GGET_SCRIPT_LOCATION}"
# Immediately exit if no arguments
[[ -z ${1} ]] && __showHelp && exit 0 || true

trap 'base::onExit $? $LINENO' EXIT
trap 'base::onError $? $LINENO' ERR

declare -r __GGET_CALLER_SCRIPT="GGet"
declare -r __BASE_ENV_VARS="^(GGET_|_+gget_+)"

declare -r __GGET_GITHUB_API_BASE_URL=api.github.com
declare -r __GGET_GITHUB_ACCEPT_RAW_HEADER="Accept:application/vnd.github.v3.raw"

# Any pair some-user/the-repo will match
declare -r __GGET_RE_PAIR="^([[:alnum:]-]+)\/([[:alnum:]-]+)*$"

# Any valid git repository URL shall match
#   https://github.com/some-user/the-repo
#   https://github.com/some-user/the-repo.git
#   git@github.com:some-user/the-repo.git
#   git://github.com/some-user/the-repo.git
declare -r __GGET_RE_FULL="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/([^.]+)(.git)*$"

gget::parseArguments() {
    # Try
    local _gget_options=$(getopt \
        -n "${__GGET_CALLER_SCRIPT}" \
        -s bash \
        -l "branch:,tag:,output:,prefix:,user:,secret:" \
        -o "b:t:o:p:u:s:" \
        -- "${@}"
    ) || { # Catch
        echo "Incorrect options provided"
        __showHelp
        exit 1
    }
    local _trailingArgs=$(base::trailingArguments "${_gget_options}")
    local _firstTrailing="${_trailingArgs%% *}"
    if [[ ! -z "${_firstTrailing}" ]]; then
        # Assign (first) trailing value to the repository URL/ShortHand
        base::setEnv GGET_REPO_SH_URL "${_firstTrailing}" 'Git Shorthand/URL'
    fi
    eval set -- "$_gget_options"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--branch)
                base::setEnv GGET_REPO_BRANCH "${2}" 'Repository Branch'
                shift 2
                ;;
            -t|--tag)
                base::setEnv GGET_REPO_TAGREF "${2}" '(Release|Tag) Ref'
                shift 2
                ;;
            -p|--prefix)
                base::setEnv GGET_REPO_PREFIX "${2}" 'Shorthands Prefix'
                shift 2
                ;;
            -u|--user)
                base::setEnv GGET_GH_USERNAME "${2}" 'Git Auth Username'
                shift 2
                ;;
            -o|--output)
                base::setEnv GGET_OUTPUT_PATH "${2}" 'Output Directory '
                shift 2
                ;;
            -s|--secret)
                base::setEnv GGET_USER_SECRET "${2}" 'User Token Secret'
                shift 2
                ;;
            --)
                shift
                break
                ;;
        esac
    done
}

gget::displayConfig() {
    env | grep -E ^GGET_[^_]
    env | grep -E ^_gget_
}

gget::parseTargetDir() {
    local _gget_targetDir=
    if [[ ! -z "${GGET_OUTPUT_PATH}" ]]; then
        _gget_targetDir=$(base::toAbsolutePath "${GGET_OUTPUT_PATH}")
        [[ ! -z ${_gget_targetDir} ]] && {
            export GGET_FILES_DIR="${_gget_targetDir}";
            return 0
        } || {
            printf "${GGET_OUTPUT_PATH} does not exist or it's not a valid directory in your system\n"
        }
    else
        base::printEmpty true "Output files path"
    fi
    if [[ -z "${GGET_FILES_DIR}" ]]; then
        echo "Your current location will de used instead"
        export GGET_FILES_DIR=$(base::toAbsolutePath ".")
    fi
}

gget::validateTokenSecret() {
    if [[ -z "${GGET_USER_SECRET}" ]]; then
        base::printEmpty true "User API Token Secret file"
        return 0
    fi
    local _gget_actualSecretPath=
    local _gget_userSecret=$(base::toAbsoluteFilePath "${GGET_USER_SECRET}")
    if [[ -f "${_gget_userSecret}" ]]; then
        _gget_actualSecretPath="${_gget_userSecret}"
    else
        # when in docker, look into the /run/secrets directory as well (if exists)
        if [[ -d "/run/secrets" ]]; then
            echo "Files in /run/secrets:"
            ls /run/secrets
            _gget_userSecret=$(basename ${GGET_USER_SECRET})
            if [[ -f "/run/secrets/${_gget_userSecret}" ]]; then
                _gget_actualSecretPath="/run/secrets/${GGET_USER_SECRET}"
            fi
        fi
    fi
    if [[ ! -z "${_gget_actualSecretPath}" ]]; then
        # Token Found in Secrets!
        set +o xtrace
        GGET__USER_API_TOKEN=$(cat ${_gget_actualSecretPath})
    else
        echo "No secrets found with such filename ${GGET_USER_SECRET}"
        exit 14
    fi
}

gget::tryParseRepoURL() {
    local _gget_url="${GGET_REPO_SH_URL}"
    if [[ -z ${_gget_url} ]]; then
        echo "Missing key argument: <GitHubUsername>/<Repository>"
        __showHelp
        exit 15
    fi
    # else...
    echo "Repo/URL: ${_gget_url}"

    # Repository "shorthand" (pair: Owner/RepoName)
    if [[ "$_gget_url" =~ $__GGET_RE_PAIR ]]; then
        _gget_hostname=github.com
        _gget_username=${BASH_REMATCH[1]}
        _gget_repoName=${BASH_REMATCH[2]}

        # Prepend the prefix -- only if it has been provided
        # and not currently included in the repository name
        if [[ ! -z ${GGET_REPO_PREFIX} ]] && [[ ! "${_gget_repoName}" =~ ^${GGET_REPO_PREFIX}.* ]]; then
            _gget_prefixed=${GGET_REPO_PREFIX}${_gget_repoName}
        fi

    # Full git URLs
    elif [[ "$_gget_url" =~ $__GGET_RE_FULL ]]; then
        _gget_hostname=${BASH_REMATCH[3]}
        _gget_username=${BASH_REMATCH[4]}
        _gget_repoName=${BASH_REMATCH[5]}
    else
        echo "The value for URL/Shorthand seems to not match any valid criteria."
        __showHelp
        exit 16
    fi

    echo "Provider: ${_gget_hostname}"
    echo "Owner:    ${_gget_username}"
    echo "Repo:     ${_gget_repoName}"
    if [[ ${_gget_prefixed} ]]; then
        echo "Alter:    ${_gget_prefixed}"
    fi
}

gget::buildFullRepositoryUrl() {
    # TODO: Include the branch/ref-tag
    # Default Branch (will take the default one since {/ref} is omitted)
    local _downloadUrl=${__GGET_GITHUB_API_BASE_URL}/repos/${_gget_username}/${1}/tarball
    echo $_downloadUrl
}

gget::checkUrlExists() {
    local _auth=${GGET_GH_USERNAME:-${_gget_username}}:${GGET__USER_API_TOKEN}
    if [[ $__GGET_WITH_CURL ]]; then
        curl -fsI -u ${_auth} https://${1} -o /dev/null && echo OK || true
    else
        wget --spider https://${_auth}@${1} &>/dev/null && echo OK || true
    fi
}

gget::cleanTargetUrl() {
    local _targetUrl=
    local _exists=
    if [[ ! -z $_gget_prefixed ]]; then
        # echo "Building prefixed"
        _targetUrl=$(gget::buildFullRepositoryUrl "${_gget_prefixed}")
        echo "Trying with ${_targetUrl}"
        _exists=$(gget::checkUrlExists "${_targetUrl}")
        if [[ ! "${_exists}" == *OK ]]; then
            unset _targetUrl
        fi
    fi
    if [[ -z $_targetUrl ]]; then
        _targetUrl=$(gget::buildFullRepositoryUrl "${_gget_repoName}")
        echo "Trying with ${_targetUrl}"
        _exists=$(gget::checkUrlExists "${_targetUrl}")
        if [[ ! "${_exists}" == *OK ]]; then
            printf "Unreachable repository!
            Please check if URLs/Shorthand is correct"
            __showHelp
            exit 4
        fi
    fi
    _gget_targetUrl="${_targetUrl}"
}

gget::downloadFiles() {
    # _gget_targetUrl       : Repository API Url    ! required
    # GGET_FILES_DIR        : Target Directory      ! required
    # _gget_username        : git Username [owner]  ! required
    # GGET__USER_API_TOKEN  : git Access Token      ? optional
    # ---
    # Disable logging (in case it has been previously enabled)
    # to avoid "leaking" the user _auth token in any trace/logs
    set +o xtrace
    local _auth=${GGET_GH_USERNAME:-${_gget_username}}:${GGET__USER_API_TOKEN}
    echo "Downloading from https://${_gget_targetUrl}"
    # Direct Download via API (will properly follow the returned redirection)
    if [[ ${__GGET_WITH_CURL} ]]; then
        curl -sL -u ${_auth} -H ${__GGET_GITHUB_ACCEPT_RAW_HEADER} https://${_gget_targetUrl} | tar xz --strip=1 -C ${GGET_FILES_DIR}
    else
        wget -qO- --header ${__GGET_GITHUB_ACCEPT_RAW_HEADER} https://${_auth}@${_gget_targetUrl}  | tar xz --strip=1 -C ${GGET_FILES_DIR}
    fi
}

gget::parseArguments "${@}"
gget::validateTokenSecret
gget::parseTargetDir
gget::tryParseRepoURL
gget::displayConfig
gget::cleanTargetUrl
gget::downloadFiles
