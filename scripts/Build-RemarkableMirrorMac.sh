#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
configuration=${CONFIGURATION:-Release}
derived_data_path=${DERIVED_DATA_PATH:-${repository_root}/artifacts/macos/DerivedData}
requested_architectures=${MACOS_ARCHITECTURES:-arm64}
project_path=${repository_root}/mirror/macos/ReMarkableMirror.xcodeproj
contract_helpers=${repository_root}/scripts/lib/RemarkableMacPrerequisiteContract.zsh
launch_services_register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
files_loopback_path=${RMMIRROR_FILES_LOOPBACK_PATH:-}
files_loopback_sha256=${RMMIRROR_FILES_LOOPBACK_SHA256:-}
files_loopback_builder=${repository_root}/scripts/Build-RemarkableFilesLoopback.ps1
files_loopback_build_directory=${repository_root}/tmp/mirror/files-loopback
files_loopback_receipt=${derived_data_path}/Build/Products/${configuration}/rmmirror-files-loopback.sha256
contract_path=${repository_root}/mirror/agent/deploy/rmmirror-prerequisites.env
xovi_archive_override=${RMMIRROR_XOVI_ARCHIVE_PATH:-}

expected_bundle_identifier=com.ifixrobots.ReMarkableMirror
case "${configuration}" in
    Debug|Release)
        ;;
    *)
        print -u2 "CONFIGURATION must be Debug or Release."
        exit 1
        ;;
esac

case "${requested_architectures}" in
    arm64|x86_64|'arm64 x86_64'|'x86_64 arm64')
        ;;
    *)
        print -u2 "MACOS_ARCHITECTURES must be arm64, x86_64, or both separated by one space."
        exit 1
        ;;
esac

if [[ ! -x "${developer_directory}/usr/bin/xcodebuild" ]]; then
    print -u2 "Stable Xcode was not found at ${developer_directory}."
    exit 1
fi
if [[ ! -x "${launch_services_register}" ]]; then
    print -u2 "LaunchServices registration tool was not found at ${launch_services_register}."
    exit 1
fi

if [[ ! -f "${contract_helpers}" || -L "${contract_helpers}" ]]; then
    print -u2 "The prerequisite contract helpers are missing or unsafe."
    exit 1
fi
source "${contract_helpers}"
if [[ ! -f "${contract_path}" || -L "${contract_path}" ]]; then
    print -u2 "The tablet prerequisite contract is missing or unsafe."
    exit 1
fi
rmmirror_validate_contract "${contract_path}"
xovi_release=$(rmmirror_contract_value "${contract_path}" RMMIRROR_XOVI_RELEASE)
xovi_archive_sha256=$(rmmirror_contract_value "${contract_path}" RMMIRROR_XOVI_ARCHIVE_SHA256)
if ! print -r -- "${xovi_release}" | LC_ALL=C /usr/bin/grep -Eq '^v[0-9]+-[0-9]+$' ||
    ! rmmirror_is_sha256 "${xovi_archive_sha256}"; then
    print -u2 "The tablet prerequisite contract contains an invalid Xovi release or digest."
    exit 1
fi
xovi_archive_path=${xovi_archive_override:-${repository_root}/tmp/mirror/xovi-${xovi_release}/xovi-aarch64.tar.gz}
xovi_archive_url=https://github.com/asivery/rm-xovi-extensions/releases/download/${xovi_release}/xovi-aarch64.tar.gz

if [[ ( -n "${files_loopback_path}" && -z "${files_loopback_sha256}" ) ||
      ( -z "${files_loopback_path}" && -n "${files_loopback_sha256}" ) ]]; then
    print -u2 "Set both RMMIRROR_FILES_LOOPBACK_PATH and RMMIRROR_FILES_LOOPBACK_SHA256, or neither."
    exit 1
fi
if [[ -z "${files_loopback_path}" ]]; then
    powershell_path=$(command -v pwsh || true)
    docker_path=$(command -v docker || true)
    if [[ -z "${powershell_path}" || -z "${docker_path}" ]]; then
        print -u2 "A local Mac build needs PowerShell 7 and Docker to build the Files loopback extension."
        exit 1
    fi
    if [[ ! -f "${files_loopback_builder}" || -L "${files_loopback_builder}" ]]; then
        print -u2 "The Files loopback builder is missing or unsafe."
        exit 1
    fi
    "${powershell_path}" \
        -NoLogo \
        -NoProfile \
        -File "${files_loopback_builder}" \
        -OutputDirectory "${files_loopback_build_directory}" \
        -Force
    files_loopback_path=${files_loopback_build_directory}/rmmirror-files-loopback.so
    files_loopback_sha256=$(/usr/bin/shasum -a 256 "${files_loopback_path}" | /usr/bin/awk '{print $1}')
fi

if [[ -z "${files_loopback_path}" || "${files_loopback_path}" != /* ||
      ! -f "${files_loopback_path}" || -L "${files_loopback_path}" ]]; then
    print -u2 "RMMIRROR_FILES_LOOPBACK_PATH must name the verified prebuilt rmmirror-files-loopback.so."
    exit 1
fi
if ! rmmirror_is_sha256 "${files_loopback_sha256}"; then
    print -u2 "RMMIRROR_FILES_LOOPBACK_SHA256 must be the verified prebuilt extension digest."
    exit 1
fi
actual_files_loopback_sha256=$(/usr/bin/shasum -a 256 "${files_loopback_path}" | /usr/bin/awk '{print $1}')
if [[ "${actual_files_loopback_sha256}" != "${files_loopback_sha256}" ]]; then
    print -u2 "The prebuilt Files loopback extension does not match its verified digest."
    exit 1
fi

if [[ "${xovi_archive_path}" != /* || -L "${xovi_archive_path}" ||
      ( -e "${xovi_archive_path}" && ! -f "${xovi_archive_path}" ) ]]; then
    print -u2 "RMMIRROR_XOVI_ARCHIVE_PATH must be a safe absolute file path."
    exit 1
fi
if [[ ! -f "${xovi_archive_path}" ]]; then
    xovi_archive_directory=${xovi_archive_path:h}
    /bin/mkdir -p "${xovi_archive_directory}"
    if [[ ! -d "${xovi_archive_directory}" || -L "${xovi_archive_directory}" ]]; then
        print -u2 "Refusing unsafe Xovi archive directory: ${xovi_archive_directory}"
        exit 1
    fi
    xovi_download=$(mktemp "${xovi_archive_directory}/.xovi-aarch64.XXXXXX")
    cleanup_xovi_download() {
        if [[ -n "${xovi_download:-}" && -e "${xovi_download}" ]]; then
            /bin/rm -f -- "${xovi_download}"
        fi
    }
    trap cleanup_xovi_download EXIT
    /usr/bin/curl \
        --fail \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --output "${xovi_download}" \
        "${xovi_archive_url}"
    downloaded_xovi_sha256=$(/usr/bin/shasum -a 256 "${xovi_download}" | /usr/bin/awk '{print $1}')
    if [[ "${downloaded_xovi_sha256}" != "${xovi_archive_sha256}" ]]; then
        print -u2 "The downloaded Xovi archive does not match the pinned digest."
        exit 1
    fi
    /bin/chmod 0644 "${xovi_download}"
    /bin/mv -f "${xovi_download}" "${xovi_archive_path}"
    xovi_download=
    trap - EXIT
fi
actual_xovi_sha256=$(/usr/bin/shasum -a 256 "${xovi_archive_path}" | /usr/bin/awk '{print $1}')
if [[ "${actual_xovi_sha256}" != "${xovi_archive_sha256}" ]]; then
    print -u2 "The Xovi archive does not match the pinned ${xovi_release} digest."
    exit 1
fi

if [[ -L "${files_loopback_receipt}" || -d "${files_loopback_receipt}" ]]; then
    print -u2 "Refusing an unsafe Files loopback build receipt path."
    exit 1
fi
/bin/rm -f -- "${files_loopback_receipt}"

RMMIRROR_FILES_LOOPBACK_PATH="${files_loopback_path}" \
RMMIRROR_FILES_LOOPBACK_SHA256="${files_loopback_sha256}" \
RMMIRROR_XOVI_ARCHIVE_PATH="${xovi_archive_path}" \
DEVELOPER_DIR=${developer_directory} \
    "${developer_directory}/usr/bin/xcodebuild" \
    -project "${project_path}" \
    -scheme ReMarkableMirror \
    -configuration "${configuration}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${derived_data_path}" \
    ARCHS="${requested_architectures}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

app_path=${derived_data_path}/Build/Products/${configuration}/reMarkable\ Mirror.app
if [[ ! -d "${app_path}" ]]; then
    print -u2 "The build completed without the expected app at ${app_path}."
    exit 1
fi

info_plist=${app_path}/Contents/Info.plist
bundle_identifier=$(plutil -extract CFBundleIdentifier raw -expect string "${info_plist}")
version=$(plutil -extract CFBundleShortVersionString raw -expect string "${info_plist}")
build_number=$(plutil -extract CFBundleVersion raw -expect string "${info_plist}")
executable=$(plutil -extract CFBundleExecutable raw -expect string "${info_plist}")
binary_path=${app_path}/Contents/MacOS/${executable}
bundled_files_loopback=${app_path}/Contents/Resources/TabletPrerequisites/rmmirror-files-loopback.so

if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "The built app has unexpected bundle identifier: ${bundle_identifier}"
    exit 1
fi
if [[ ! -x "${binary_path}" ]]; then
    print -u2 "The built app is missing its executable: ${executable}"
    exit 1
fi
if [[ ! -f "${bundled_files_loopback}" || -L "${bundled_files_loopback}" ]]; then
    print -u2 "The built app is missing its verified Files loopback extension."
    exit 1
fi
bundled_files_loopback_sha256=$(/usr/bin/shasum -a 256 "${bundled_files_loopback}" | /usr/bin/awk '{print $1}')
if [[ "${bundled_files_loopback_sha256}" != "${files_loopback_sha256}" ]]; then
    print -u2 "The built app's Files loopback extension differs from the verified build."
    exit 1
fi
receipt_temporary=$(mktemp "${files_loopback_receipt}.XXXXXX")
cleanup_receipt() {
    if [[ -n "${receipt_temporary:-}" && -e "${receipt_temporary}" ]]; then
        /bin/rm -f -- "${receipt_temporary}"
    fi
}
trap cleanup_receipt EXIT
print -r -- "${files_loopback_sha256}" > "${receipt_temporary}"
/bin/chmod 0644 "${receipt_temporary}"
/bin/mv -f "${receipt_temporary}" "${files_loopback_receipt}"
receipt_temporary=
trap - EXIT

architectures=$(lipo -archs "${binary_path}")
requested_architecture_values=(${=requested_architectures})
built_architecture_values=(${=architectures})
if (( ${#requested_architecture_values} != ${#built_architecture_values} )); then
    print -u2 "The built architectures do not match the request: ${architectures}"
    exit 1
fi
for requested_architecture in ${requested_architecture_values}; do
    if (( ${built_architecture_values[(Ie)${requested_architecture}]} == 0 )); then
        print -u2 "The built architectures do not match the request: ${architectures}"
        exit 1
    fi
done

signature_label=unsigned
if signature_details=$(codesign -dv --verbose=2 "${app_path}" 2>&1) &&
    codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1; then
    if [[ "${signature_details}" == *"Signature=adhoc"* ]]; then
        signature_label=ad-hoc
    else
        signature_label=signed
    fi
fi

launch_services_status="removed for build output"
if ! "${launch_services_register}" -u "${app_path}"; then
    launch_services_status="unregistration unavailable; build output was not launched"
    print -u2 "Warning: LaunchServices could not unregister the build output."
fi

print "Built reMarkable Mirror ${version} (${build_number}) for ${architectures}."
print "Bundle identifier: ${bundle_identifier}"
print "Signing status: ${signature_label}"
print "LaunchServices registration: ${launch_services_status}"
print "Local app: ${app_path}"
