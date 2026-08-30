#!/bin/zsh

set -euo pipefail

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" ||
      -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" || -z "${DERIVED_FILE_DIR:-}" ]]; then
    print -u2 "Required Xcode build paths are unavailable."
    exit 1
fi

export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/go/bin"
repository_root="${SRCROOT}/../.."
builder="${repository_root}/scripts/Build-RemarkableTransportWakeMac.sh"
contract_helpers="${repository_root}/scripts/lib/RemarkableMacPrerequisiteContract.zsh"
deploy_directory="${repository_root}/mirror/agent/deploy"
notice_source_directory="${repository_root}/mirror/third-party/xovi"
third_party_notices_source="${repository_root}/THIRD_PARTY_NOTICES.md"
resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
destination="${resources_directory}/TabletPrerequisites"
legacy_destination="${resources_directory}/TabletTransportWake"
notice_parent="${resources_directory}/ThirdParty"
notice_destination="${notice_parent}/Xovi"
third_party_notices_destination="${resources_directory}/THIRD_PARTY_NOTICES.md"
files_loopback_path=${RMMIRROR_FILES_LOOPBACK_PATH:-}
files_loopback_sha256=${RMMIRROR_FILES_LOOPBACK_SHA256:-}
xovi_archive_path=${RMMIRROR_XOVI_ARCHIVE_PATH:-}
contract_path=${deploy_directory}/rmmirror-prerequisites.env

require_regular_file() {
    local candidate=$1
    local label=$2
    if [[ ! -f "${candidate}" || -L "${candidate}" ]]; then
        print -u2 "${label} is missing, non-regular, or a symbolic link: ${candidate}"
        exit 1
    fi
}

if [[ ! -f "${builder}" || ! -x "${builder}" || -L "${builder}" ]]; then
    print -u2 "The verified Linux ARM64 builder is missing or unsafe."
    exit 1
fi
require_regular_file "${contract_helpers}" "The prerequisite contract helpers"
source "${contract_helpers}"
require_regular_file "${contract_path}" "The tablet prerequisite contract"
rmmirror_validate_contract "${contract_path}"
xovi_release=$(rmmirror_contract_value "${contract_path}" RMMIRROR_XOVI_RELEASE)
xovi_archive_sha256=$(rmmirror_contract_value "${contract_path}" RMMIRROR_XOVI_ARCHIVE_SHA256)
if ! print -r -- "${xovi_release}" | LC_ALL=C /usr/bin/grep -Eq '^v[0-9]+-[0-9]+$' ||
    ! rmmirror_is_sha256 "${xovi_archive_sha256}"; then
    print -u2 "The tablet prerequisite contract contains an invalid Xovi release or digest."
    exit 1
fi
if [[ -z "${files_loopback_path}" || "${files_loopback_path}" != /* ]]; then
    print -u2 "RMMIRROR_FILES_LOOPBACK_PATH must be a safe absolute file path."
    exit 1
fi
if ! rmmirror_is_sha256 "${files_loopback_sha256}"; then
    print -u2 "RMMIRROR_FILES_LOOPBACK_SHA256 must be a lowercase SHA-256 digest."
    exit 1
fi
if [[ -z "${xovi_archive_path}" || "${xovi_archive_path}" != /* ]]; then
    print -u2 "RMMIRROR_XOVI_ARCHIVE_PATH must be a safe absolute file path."
    exit 1
fi
require_regular_file "${files_loopback_path}" "The prebuilt Files loopback extension"
require_regular_file "${xovi_archive_path}" "The pinned Xovi archive"

actual_files_loopback_sha256=$(/usr/bin/shasum -a 256 "${files_loopback_path}" | /usr/bin/awk '{print $1}')
if [[ "${actual_files_loopback_sha256}" != "${files_loopback_sha256}" ]]; then
    print -u2 "The prebuilt Files loopback extension does not match its verified digest."
    exit 1
fi
actual_xovi_sha256=$(/usr/bin/shasum -a 256 "${xovi_archive_path}" | /usr/bin/awk '{print $1}')
if [[ "${actual_xovi_sha256}" != "${xovi_archive_sha256}" ]]; then
    print -u2 "The Xovi archive does not match the pinned digest."
    exit 1
fi

/bin/mkdir -p "${DERIVED_FILE_DIR}" "${resources_directory}" "${notice_parent}"
for safe_directory in \
    "${DERIVED_FILE_DIR}" \
    "${resources_directory}" \
    "${notice_parent}"; do
    if [[ ! -d "${safe_directory}" || -L "${safe_directory}" ]]; then
        print -u2 "Refusing unsafe build resource directory: ${safe_directory}"
        exit 1
    fi
done

stage_directory=$(mktemp -d "${DERIVED_FILE_DIR}/TabletPrerequisites.XXXXXX")
notice_stage=$(mktemp -d "${DERIVED_FILE_DIR}/XoviNotices.XXXXXX")
cleanup() {
    for candidate in "${stage_directory:-}" "${notice_stage:-}"; do
        if [[ -n "${candidate}" && -d "${candidate}" ]]; then
            /bin/rm -rf -- "${candidate}"
        fi
    done
}
trap cleanup EXIT

"${builder}" "${stage_directory}/rmmirror-transport-wake"
"${builder}" "${stage_directory}/rmmirror-probe"

for name in \
    rmmirror-transport-wake.service \
    install-transport-wake.sh \
    rmmirror-usb-sleep-guard.conf \
    install-mirror-prerequisites.sh \
    rmmirror-prerequisites.env; do
    source_path="${deploy_directory}/${name}"
    require_regular_file "${source_path}" "Tablet prerequisite source asset"
    /bin/cp -f "${source_path}" "${stage_directory}/${name}"
done
/bin/cp -f "${files_loopback_path}" "${stage_directory}/rmmirror-files-loopback.so"
/bin/cp -f "${xovi_archive_path}" "${stage_directory}/xovi-aarch64.tar.gz"

/bin/chmod 0644 "${stage_directory}"/*
/bin/chmod 0755 \
    "${stage_directory}/rmmirror-transport-wake" \
    "${stage_directory}/rmmirror-probe"

typeset -a payload_entries
payload_entries=("${stage_directory}"/*(DN))
if (( ${#payload_entries} != 9 )); then
    print -u2 "The tablet prerequisite payload must contain exactly nine assets."
    exit 1
fi

for name in NOTICE.txt LICENSE-GPL-3.0.txt; do
    source_path="${notice_source_directory}/${name}"
    require_regular_file "${source_path}" "Xovi notice source"
    /bin/cp -f "${source_path}" "${notice_stage}/${name}"
    /bin/chmod 0644 "${notice_stage}/${name}"
done
typeset -a notice_entries
notice_entries=("${notice_stage}"/*(DN))
if (( ${#notice_entries} != 2 )); then
    print -u2 "The Xovi notice directory must contain exactly two files."
    exit 1
fi

require_regular_file "${third_party_notices_source}" "The repository third-party notices"
if [[ -L "${third_party_notices_destination}" ||
      ( -e "${third_party_notices_destination}" && ! -f "${third_party_notices_destination}" ) ]]; then
    print -u2 "Refusing unsafe third-party notices destination."
    exit 1
fi
/bin/cp -f "${third_party_notices_source}" "${third_party_notices_destination}"
/bin/chmod 0644 "${third_party_notices_destination}"

for candidate in "${destination}" "${notice_destination}"; do
    if [[ -e "${candidate}" || -L "${candidate}" ]]; then
        if [[ ! -d "${candidate}" || -L "${candidate}" ]]; then
            print -u2 "Refusing unsafe build resource destination: ${candidate}"
            exit 1
        fi
        /bin/rm -rf -- "${candidate}"
    fi
done
if [[ -e "${legacy_destination}" || -L "${legacy_destination}" ]]; then
    if [[ ! -d "${legacy_destination}" || -L "${legacy_destination}" ]]; then
        print -u2 "Refusing unsafe legacy tablet resource destination: ${legacy_destination}"
        exit 1
    fi
    /bin/rm -rf -- "${legacy_destination}"
fi
/bin/mv "${stage_directory}" "${destination}"
stage_directory=
/bin/mv "${notice_stage}" "${notice_destination}"
notice_stage=
