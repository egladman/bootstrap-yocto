#!/bin/bash

#Defaults
VERBOSE=0
BASE_PATH="/tmp"
YOCTO_TARGET="f1c100s"
CURRENT_WORKING_DIR=$(pwd)
YOCTO_BUILD_USER=$(whoami)
YOCTO_TEMP_DIR=""
YOCTO_RESULTS_DIR=""
BITBAKE_RECIPE="core-image-minimal"
GIT_REPO_NAME=""
GIT_REPO_BRANCH=""
GIT_COMMIT_HASH=""

export YOCTO_RELEASE="pyro"
export YOCTO_DISTRO="poky-tiny"

RED="\033[0;31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m" #No color

_log() {
    echo -e ${0##*/}: "${@}" 1>&2
}

_debug() {
  #  if [ "${VERBOSE}" -eq 1 ]; then
        _log "${CYAN}DEBUG:${NC} ${@}"
   # fi
}

_warn() {
    _log "${YELLOW}WARNING:${NC} ${@}"
}

_success() {
    _log "${GREEN}SUCCESS:${NC} ${@}"
}

_die() {
    _log "${RED}FATAL:${NC} ${@}"
    _cleanup
    if [ "${VERBOSE}" -eq 1 ]; then
	_debug "Killing process in 15 seconds..."
	sleep 15s
    fi
    exit 1
}

_cleanup() {
    #TODO: check if i need to disable virtualenv
    rm -rf ${TEMP_DIR}
}

#Compares semantic versions
_compare_versions () {
    if [ ! -z $3 ]; then
        _die  "More than two arguments were passed in!"
    fi

    if [ $1 = $2 ]; then
        echo 0 && return
    fi

    if [[ $2 = $(echo $@ | tr " " "\n" | sort -V | head -n1) ]]; then
        echo 1 && return
    fi

    if [[ $1 = $(echo $@ | tr " " "\n" | sort -V | head -n1) ]]; then
        echo -1 && return
    fi
}

#Check if the script is ran with elevated permissions
if [ "${EUID}" -eq 1 ]; then
    _die "${0##*/} should not be ran with sudo"
fi

apt_dependencies=(
    "gawk"
    "bzip2"
    "wget"
    "git-core"
    "diffstat"
    "unzip"
    "texinfo"
    "gcc-multilib"
    "build-essential"
    "chrpath"
    "socat"
    "cpio"
    "python"
    "python3"
    "python3-pip"
    "python3-pexpect"
    "xz-utils"
    "debianutils"
    "iputils-ping"
    "libsdl1.2-dev"
    "xterm"
    "python-pip"
    "virtualenv"
)
dnf_dependencies=(
    "gawk"
    "bzip2"
    "make"
    "wget"
    "tar"
    "bzip2"
    "gzip"
    "python3"
    "unzip"
    "perl"
    "patch"
    "diffutils"
    "diffstat"
    "git"
    "cpp"
    "gcc"
    "gcc-c++"
    "glibc-devel"
    "texinfo"
    "chrpath"
    "ccache"
    "perl-Data-Dumper"
    "perl-Text-ParseWords"
    "perl-Thread-Queue"
    "perl-bignum"
    "socat"
    "python3-pexpect"
    "findutils"
    "which"
    "file"
    "cpio"
    "python"
    "python3-pip"
    "xz"
    "SDL-devel"
    "xterm"
    "texinfo"
    "cpan"
    "python2"
    "virtualenv"
    "rpcgen"
)

_usage() {
cat << EOF

${0##*/} [-h] [-v] [-r string] [-p string] [-b path/to/directory] [-t string] -- setup yocto and compile/upload image
where:
    -h  show this help text
    -r  set yocto project release (default: ${YOCTO_RELEASE})
    -b  set path for temporary files (default: ${BASE_PATH})
    -t  set target (default: ${YOCTO_TARGET})
    -p  set bitbake recipe (default: ${BITBAKE_RECIPE})
    -u  set yocto build user
    -v  verbose output

EOF
}

while getopts ':h :v :s r: t: b: e: u: p:' option; do
    case "${option}" in
        h|\?) _usage
           exit 0
           ;;
        v) VERBOSE=1
           ;;
        r) YOCTO_RELEASE="${OPTARG}"
	   _debug "YOCTO_RELEASE overrided to ${OPTARG}"
           ;;
        b) BASE_PATH="${OPTARG}"
	   _debug "BASE_PATH overrided to ${OPTARG}"
           ;;
        t) TARGET="${OPTARG}"
	   _debug "TARGET overrided to ${OPTARG}"
           ;;
        p) BITBAKE_RECIPE="${OPTARG}"
	   _debug "BITBAKE_RECIPE overrided to ${OPTARG}"
           ;;
        u) YOCTO_BUILD_USER="${OPTARG}"
	   _debug "YOCTO_BUILD_USER overrided to ${OPTARG}"
           ;;
        :) printf "missing argument for -%s\n" "${OPTARG}"
           _usage
           exit 1
           ;;
    esac
done
shift $((OPTIND - 1))

GIT_REPO_NAME=$(basename $(git rev-parse --show-toplevel))
GIT_COMMIT_HASH=$(git rev-parse --short HEAD)

if [ "${CI}" = "true" ]; then
    GIT_REPO_BRANCH="${BRANCH}" #BRANCH is an environment variable provided by shippable
else
    GIT_REPO_BRANCH=$(git branch 2>/dev/null | grep '^*' | cut -d' ' -f2)
fi

_debug "repo name: ${GIT_REPO_NAME}"
_debug "repo branch: ${GIT_REPO_BRANCH}"
_debug "commit hash: ${GIT_COMMIT_HASH}"

_debug "Checking if build user: ${YOCTO_BUILD_USER} exists..."
if [ $(id -u "${YOCTO_BUILD_USER}" 2>/dev/null || echo -1) -ge 0 ]; then
    _debug "Build user already exists. Proceeding..."
else
    _log "User: ${YOCTO_BUILD_USER} does not exist. Creating..."
    sudo useradd "${YOCTO_BUILD_USER}" || _die "Failed to create user: ${YOCTO_BUILD_USER}"
    sudo passwd -d "${YOCTO_BUILD_USER}" || _die "Failed to delete password for user: ${YOCTO_BUILD_USER}"
    sudo usermod -aG sudo "${YOCTO_BUILD_USER}" || _die "Failed to add user: "${YOCTO_BUILD_USER}" to group: sudo"
fi

_debug "Installing package dependencies..."
#Install fedora dependencies
if [ $(command -v dnf) ]; then
    sudo dnf update -y && sudo dnf install -y "${dnf_dependencies[@]}"
fi

#Install ubuntu/debian dependencies
command -v apt-get >/dev/null 2>&1 && sudo apt-get update -y && sudo apt-get install -y "${apt_dependencies[@]}"

#Auto-configure cpan
if [ "${CI}" = "true" ]; then
    (echo y;echo o conf prerequisites_policy follow;echo o conf commit)|cpan || {
        _die "Failed to setup cpan."
    }
fi

#If running locally and the following line fails run "cpan" to manually configure cpan
cpan install bignum bigint || _die "Failed to install perl modules."

#Check if directory doesn't exist
if [ ! -d "${BASE_PATH}" ]; then
    _die "Directory: ${BASE_PATH} does not exist!"
fi

export YOCTO_TEMP_DIR=$(mktemp -t yocto.XXXXXXXX -p "${BASE_PATH}" --directory --dry-run) #There are better ways of doing this. Chance of collison

mkdir "${YOCTO_TEMP_DIR}" || _die "Failed to create temporary directory: ${YOCTO_TEMP_DIR}"

_debug "Yocto Project Release: ${YOCTO_RELEASE}"

#TODO: git:// is insecure. use https or ssh
_debug "Cloning poky..."
git clone -b "${YOCTO_RELEASE}" https://git.yoctoproject.org/git/poky "${YOCTO_TEMP_DIR}"/poky || _die "Failed to clone poky repository"

_debug "Cloning meta-openembedded..."
git clone -b "${YOCTO_RELEASE}" https://git.openembedded.org/meta-openembedded "${YOCTO_TEMP_DIR}"/poky/meta-openembedded || _die "Failed to clone meta-openembedded repository"

_debug "Cloning meta-raspberrypi..."
git clone -b "${YOCTO_RELEASE}" https://github.com/egladman/meta-sunxi.git "${YOCTO_TEMP_DIR}"/poky/meta-sunxi || _die "Failed to clone meta-sunxi repository"

#Create custom bblayers.conf
mkdir -p "${YOCTO_TEMP_DIR}"/rpi/build/conf
sudo chmod -R 777 "${YOCTO_TEMP_DIR}" || _die "Failed to change directory: ${YOCTO_TEMP_DIR} permissions"

cat << EOF >> "${YOCTO_TEMP_DIR}"/rpi/build/conf/bblayers.conf || _die "Failed to create ${YOCTO_TEMP_DIR}/rpi/build/conf/bblayers.conf"
# POKY_BBLAYERS_CONF_VERSION is increased each time build/conf/bblayers.conf
# changes incompatibly
POKY_BBLAYERS_CONF_VERSION = "2"

BBPATH = "\${TOPDIR}"
BBFILES ?= ""

BBLAYERS ?= " \
  ${YOCTO_TEMP_DIR}/poky/meta \
  ${YOCTO_TEMP_DIR}/poky/meta-poky \
  ${YOCTO_TEMP_DIR}/poky/meta-openembedded/meta-oe \
  ${YOCTO_TEMP_DIR}/poky/meta-sunxi \
  "

BBLAYERS_NON_REMOVABLE ?= " \
  ${YOCTO_TEMP_DIR}/poky/meta \
  ${YOCTO_TEMP_DIR}/poky/meta-poky \
  "

EOF

YOCTO_EXTRA_PACKAGES=(    #layer dependency
    "curl"
    "ethtool"
    "gawk"
    "git"          
    "i2c-tools"
    "jq"
    "nano"
    "openssh"
    "rsync"        
    "traceroute"
    "vi"
)

YOCTO_EXTRA_IMAGE_FEATURES=(
    "package-management"  #https://wiki.yoctoproject.org/wiki/Smart
)

#Quick hack that if we're totally honest, probably won't be fixed
#I was having problems preserving env variables across su (and yeah I know there's a param that SHOULD allow this)
#We aren't writting anything sensitive, but it's still a bad practice

#TODO: Use named pipe instead of writting to file
mkdir -p /tmp/bootstrap-yocto/env || _die "Failed to create /tmp/bootstrap-yocto/env"
variables=(
    "YOCTO_TEMP_DIR"
    "YOCTO_TARGET"
    "YOCTO_DISTRO"
    "BITBAKE_RECIPE"
    "YOCTO_EXTRA_PACKAGES"
    "YOCTO_EXTRA_IMAGE_FEATURES"
)
for var in ${variables[@]}; do
    if [ -z $(eval echo \$$var) ]; then
        _die "One or more variables are not valid. Only reference variables that have been previously defined."
    fi

    #check if variable is an array
    if [[ $(declare -p $var) == "declare -a"* ]]; then
        _debug "${var}: $(eval echo \${$var[@]})"
        echo $(eval echo \${$var[@]}) > /tmp/bootstrap-yocto/env/"${var}" || _die "Failed to write array to file."
    else
        _debug "${var}: $(eval echo \$$var)"
        echo $(eval echo \$$var) > /tmp/bootstrap-yocto/env/"${var}" || _die "Failed to write string to file."
    fi
done

#oe-init-build requires python2
virtualenv -p /usr/bin/python2.7 --distribute temp-python
#source temp-python/bin/activate

_debug "Building image. Additional images can be found in ${YOCTO_TEMP_DIR}/meta*/recipes*/images/*.bb"
sudo su "${YOCTO_BUILD_USER}" -p -c '\
    YOCTO_TEMP_DIR="$(cat /tmp/bootstrap-yocto/env/YOCTO_TEMP_DIR)" && \
    YOCTO_TARGET="$(cat /tmp/bootstrap-yocto/env/YOCTO_TARGET)" && \
    BITBAKE_RECIPE="$(cat /tmp/bootstrap-yocto/env/BITBAKE_RECIPE)" && \
    YOCTO_EXTRA_PACKAGES="$(cat /tmp/bootstrap-yocto/env/YOCTO_EXTRA_PACKAGES)" && \
    YOCTO_EXTRA_IMAGE_FEATURES="$(cat /tmp/bootstrap-yocto/env/YOCTO_EXTRA_IMAGE_FEATURES)" && \
    YOCTO_DISTRO="$(cat /tmp/bootstrap-yocto/env/YOCTO_DISTRO)" && \

    source temp-python/bin/activate && \
    source "${YOCTO_TEMP_DIR}"/poky/oe-init-build-env "${YOCTO_TEMP_DIR}"/rpi/build && \
    echo MACHINE ??= \"${YOCTO_TARGET}\" >> "${YOCTO_TEMP_DIR}"/rpi/build/conf/local.conf && \
    echo CORE_IMAGE_EXTRA_INSTALL += \"${YOCTO_EXTRA_PACKAGES}\" >> "${YOCTO_TEMP_DIR}"/rpi/build/conf/local.conf && \
    echo EXTRA_IMAGE_FEATURES += \"${YOCTO_EXTRA_IMAGE_FEATURES}\" >> "${YOCTO_TEMP_DIR}"/rpi/build/conf/local.conf && \
    echo DISTRO = \"${YOCTO_DISTRO}\" >> "${YOCTO_TEMP_DIR}"/rpi/build/conf/local.conf && \

    #Debugging
    echo -e "\n!!!! start of conf/local.conf !!!!\n" && \
    cat "${YOCTO_TEMP_DIR}"/rpi/build/conf/local.conf && \
    echo -e "\n!!!! end of conf/local.conf !!!!\n" && \

    bitbake "${BITBAKE_RECIPE}"' && _success "The image was successfully compiled ♥‿♥" || {
        _die "Failed to build image ಥ﹏ಥ"
    }

YOCTO_RESULTS_DIR="${YOCTO_TEMP_DIR}/rpi/build/tmp/deploy/images/${YOCTO_TARGET}"
_debug "Directory Results: $(ls ${YOCTO_RESULTS_DIR})"

#Cherry pick the files we care about...
YOCTO_RESULTS_BASENAME=$(basename "${YOCTO_RESULTS_SDIMG}" .rpi-sdimg)
YOCTO_RESULTS_EXT3=$(ls "${YOCTO_RESULTS_DIR}"/*.rootfs.ext3)
YOCTO_RESULTS_SDIMG=$(ls "${YOCTO_RESULTS_DIR}"/*.rootfs.rpi-sdimg)

#We force bzip since the target is linked, otherwise bzip will fail
_debug "Compressing images..."
bzip2 --force "${YOCTO_RESULTS_SDIMG}" || _die "Failed to bzip ${YOCTO_RESULTS_SDIMG}"
bzip2 --force "${YOCTO_RESULTS_EXT3}" || _die "Failed to bzip ${YOCTO_RESULTS_EXT3}"

_debug "Generating sha256sums..."
echo $(sha256sum "${YOCTO_RESULTS_SDIMG}.bz2" "${YOCTO_RESULTS_EXT3}.bz2") > "${YOCTO_RESULTS_DIR}"/$(basename "${YOCTO_RESULTS_SDIMG}" .rootfs.rpi-sdimg).sha256sums || _die "Failed to generate sha256sums."
