#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
configuration=${CONFIGURATION:-Release}
derived_data_path=${DERIVED_DATA_PATH:-${repository_root}/artifacts/macos/DerivedData}
app_path=${derived_data_path}/Build/Products/${configuration}/reMarkable\ Mirror.app
package_directory=${MACOS_PACKAGE_DIRECTORY:-${repository_root}/artifacts/macos/package}
signing_identity=${MACOS_SIGNING_IDENTITY:-}
notary_keychain_profile=${MACOS_NOTARY_KEYCHAIN_PROFILE:-}
expected_bundle_identifier=com.ifixrobots.ReMarkableMirror

if [[ ! -d "${app_path}" ]]; then
    print -u2 "Build the app first with scripts/Build-RemarkableMirrorMac.sh."
    exit 1
fi

info_plist=${app_path}/Contents/Info.plist
version=$(plutil -extract CFBundleShortVersionString raw -expect string "${info_plist}")
build_number=$(plutil -extract CFBundleVersion raw -expect string "${info_plist}")
bundle_identifier=$(plutil -extract CFBundleIdentifier raw -expect string "${info_plist}")
executable=$(plutil -extract CFBundleExecutable raw -expect string "${info_plist}")
binary_path=${app_path}/Contents/MacOS/${executable}
tablet_prerequisite_asset_directory_name=TabletPrerequisites
tablet_prerequisite_source_directory=${repository_root}/mirror/agent/deploy
contract_path=${tablet_prerequisite_source_directory}/rmmirror-prerequisites.env
contract_helpers=${repository_root}/scripts/lib/RemarkableMacPrerequisiteContract.zsh
xovi_notice_source_directory=${repository_root}/mirror/third-party/xovi
third_party_notices_source=${repository_root}/THIRD_PARTY_NOTICES.md
files_loopback_sha256=${RMMIRROR_FILES_LOOPBACK_SHA256:-}
files_loopback_receipt=${derived_data_path}/Build/Products/${configuration}/rmmirror-files-loopback.sha256

if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "Refusing to package unexpected bundle identifier: ${bundle_identifier}"
    exit 1
fi
if ! print -r -- "${version}" | grep -Eq '^[0-9]+([.][0-9]+){1,2}$'; then
    print -u2 "Refusing to package invalid app version: ${version}"
    exit 1
fi
if [[ "${build_number}" != <-> ]]; then
    print -u2 "Refusing to package invalid build number: ${build_number}"
    exit 1
fi
if [[ ! -x "${binary_path}" ]]; then
    print -u2 "The app is missing its executable: ${executable}"
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
if [[ -z "${files_loopback_sha256}" ]]; then
    if [[ ! -f "${files_loopback_receipt}" || -L "${files_loopback_receipt}" ]]; then
        print -u2 "The Files loopback build receipt is missing. Build the app again before packaging it."
        exit 1
    fi
    IFS= read -r files_loopback_sha256 < "${files_loopback_receipt}" || true
fi
if ! rmmirror_is_sha256 "${files_loopback_sha256}"; then
    print -u2 "The Files loopback build receipt does not contain a verified digest."
    exit 1
fi

assert_aarch64_elf() {
    local candidate=$1
    local expected_type=$2
    local label=$3
    local raw
    local -a bytes elf_type_bytes machine_bytes offset_bytes entry_size_bytes count_bytes type_bytes
    local elf_type machine program_header_offset program_header_entry_size program_header_count
    local file_size entry_offset program_header_type index

    if [[ ! -f "${candidate}" || -L "${candidate}" ]]; then
        print -u2 "Refusing ${label} that is missing or a symbolic link: ${candidate}"
        return 1
    fi
    file_size=$(/usr/bin/stat -f '%z' "${candidate}")
    if (( file_size < 64 )); then
        print -u2 "Refusing ${label} that is too small to be ELF."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 0 -N 7 "${candidate}")
    bytes=(${=raw})
    if (( ${#bytes} != 7 )) ||
        (( bytes[1] != 127 || bytes[2] != 69 || bytes[3] != 76 || bytes[4] != 70 )); then
        print -u2 "Refusing ${label} that is not ELF."
        return 1
    fi
    if (( bytes[5] != 2 || bytes[6] != 1 || bytes[7] != 1 )); then
        print -u2 "Refusing ${label} that is not 64-bit little-endian ELF."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 16 -N 2 "${candidate}")
    elf_type_bytes=(${=raw})
    if (( ${#elf_type_bytes} != 2 )); then
        print -u2 "Refusing ${label} with a truncated ELF type field."
        return 1
    fi
    elf_type=$(( elf_type_bytes[1] | (elf_type_bytes[2] << 8) ))
    if (( elf_type != expected_type )); then
        print -u2 "Refusing ${label} with ELF type ${elf_type}; expected ${expected_type}."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 18 -N 2 "${candidate}")
    machine_bytes=(${=raw})
    if (( ${#machine_bytes} != 2 )); then
        print -u2 "Refusing ${label} with a truncated ELF machine field."
        return 1
    fi
    machine=$(( machine_bytes[1] | (machine_bytes[2] << 8) ))
    if (( machine != 183 )); then
        print -u2 "Refusing ${label} with ELF machine ${machine}; expected AArch64 183."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 32 -N 8 "${candidate}")
    offset_bytes=(${=raw})
    if (( ${#offset_bytes} != 8 )) ||
        (( offset_bytes[5] != 0 || offset_bytes[6] != 0 || offset_bytes[7] != 0 || offset_bytes[8] != 0 )); then
        print -u2 "Refusing ${label} with an unsupported ELF program-header offset."
        return 1
    fi
    program_header_offset=$((
        offset_bytes[1] |
        (offset_bytes[2] << 8) |
        (offset_bytes[3] << 16) |
        (offset_bytes[4] << 24)
    ))

    raw=$(/usr/bin/od -An -v -tu1 -j 54 -N 2 "${candidate}")
    entry_size_bytes=(${=raw})
    raw=$(/usr/bin/od -An -v -tu1 -j 56 -N 2 "${candidate}")
    count_bytes=(${=raw})
    if (( ${#entry_size_bytes} != 2 || ${#count_bytes} != 2 )); then
        print -u2 "Refusing ${label} with a truncated ELF program-header table."
        return 1
    fi
    program_header_entry_size=$(( entry_size_bytes[1] | (entry_size_bytes[2] << 8) ))
    program_header_count=$(( count_bytes[1] | (count_bytes[2] << 8) ))
    if (( program_header_entry_size != 56 || program_header_count == 0 || program_header_count > 256 )); then
        print -u2 "Refusing ${label} with an invalid ELF program-header table."
        return 1
    fi
    if (( program_header_offset < 64 ||
          program_header_offset + (program_header_entry_size * program_header_count) > file_size )); then
        print -u2 "Refusing ${label} with an out-of-bounds ELF program-header table."
        return 1
    fi

    for (( index = 0; index < program_header_count; index++ )); do
        entry_offset=$(( program_header_offset + (index * program_header_entry_size) ))
        raw=$(/usr/bin/od -An -v -tu1 -j ${entry_offset} -N 4 "${candidate}")
        type_bytes=(${=raw})
        if (( ${#type_bytes} != 4 )); then
            print -u2 "Refusing ${label} with a truncated ELF program header."
            return 1
        fi
        program_header_type=$((
            type_bytes[1] |
            (type_bytes[2] << 8) |
            (type_bytes[3] << 16) |
            (type_bytes[4] << 24)
        ))
        if (( program_header_type == 3 )); then
            print -u2 "Refusing ${label} with a dynamic ELF interpreter."
            return 1
        fi
    done
}

assert_tablet_prerequisite_assets() {
    local candidate_app=$1
    local asset_directory=${candidate_app}/Contents/Resources/${tablet_prerequisite_asset_directory_name}
    local legacy_asset_directory=${candidate_app}/Contents/Resources/TabletTransportWake
    local notice_directory=${candidate_app}/Contents/Resources/ThirdParty/Xovi
    local bundled_third_party_notices=${candidate_app}/Contents/Resources/THIRD_PARTY_NOTICES.md
    local name source_path candidate_path safe_directory actual_hash
    local -a expected_names entries expected_notice_names notice_entries

    if [[ -e "${legacy_asset_directory}" || -L "${legacy_asset_directory}" ]]; then
        print -u2 "Refusing app with the obsolete TabletTransportWake payload."
        return 1
    fi

    expected_names=(
        rmmirror-transport-wake
        rmmirror-transport-wake.service
        install-transport-wake.sh
        rmmirror-usb-sleep-guard.conf
        rmmirror-probe
        xovi-aarch64.tar.gz
        rmmirror-files-loopback.so
        install-mirror-prerequisites.sh
        rmmirror-prerequisites.env
    )
    expected_notice_names=(NOTICE.txt LICENSE-GPL-3.0.txt)
    for safe_directory in \
        "${candidate_app}" \
        "${candidate_app}/Contents" \
        "${candidate_app}/Contents/Resources" \
        "${asset_directory}" \
        "${candidate_app}/Contents/Resources/ThirdParty" \
        "${notice_directory}"; do
        if [[ ! -d "${safe_directory}" || -L "${safe_directory}" ]]; then
            print -u2 "Refusing app without a safe tablet prerequisite resource path."
            return 1
        fi
    done

    entries=("${asset_directory}"/*(DN))
    if (( ${#entries} != ${#expected_names} )); then
        print -u2 "Refusing app whose ${tablet_prerequisite_asset_directory_name} directory does not contain exactly nine assets."
        return 1
    fi
    for name in ${expected_names}; do
        candidate_path=${asset_directory}/${name}
        if [[ ! -f "${candidate_path}" || -L "${candidate_path}" ]]; then
            print -u2 "Refusing app with missing, non-regular, or symbolic-link tablet prerequisite asset: ${name}"
            return 1
        fi
    done
    for candidate_path in ${entries}; do
        if (( ${expected_names[(Ie)${candidate_path:t}]} == 0 )); then
            print -u2 "Refusing unexpected tablet prerequisite asset: ${candidate_path:t}"
            return 1
        fi
    done

    for name in \
        rmmirror-transport-wake.service \
        install-transport-wake.sh \
        rmmirror-usb-sleep-guard.conf \
        install-mirror-prerequisites.sh \
        rmmirror-prerequisites.env; do
        source_path=${tablet_prerequisite_source_directory}/${name}
        candidate_path=${asset_directory}/${name}
        if [[ ! -f "${source_path}" || -L "${source_path}" ]]; then
            print -u2 "Tablet prerequisite source asset is missing or unsafe: ${source_path}"
            return 1
        fi
        if ! /usr/bin/cmp -s "${source_path}" "${candidate_path}"; then
            print -u2 "Refusing tablet prerequisite asset that differs from the repository source: ${name}"
            return 1
        fi
    done

    actual_hash=$(/usr/bin/shasum -a 256 "${asset_directory}/xovi-aarch64.tar.gz" | /usr/bin/awk '{print $1}')
    if [[ "${actual_hash}" != "${xovi_archive_sha256}" ]]; then
        print -u2 "Refusing Xovi archive that differs from the pinned digest."
        return 1
    fi
    actual_hash=$(/usr/bin/shasum -a 256 "${asset_directory}/rmmirror-files-loopback.so" | /usr/bin/awk '{print $1}')
    if [[ "${actual_hash}" != "${files_loopback_sha256}" ]]; then
        print -u2 "Refusing Files loopback extension that differs from the verified build."
        return 1
    fi

    notice_entries=("${notice_directory}"/*(DN))
    if (( ${#notice_entries} != ${#expected_notice_names} )); then
        print -u2 "Refusing app whose Xovi notice directory does not contain exactly two files."
        return 1
    fi
    for name in ${expected_notice_names}; do
        source_path=${xovi_notice_source_directory}/${name}
        candidate_path=${notice_directory}/${name}
        if [[ ! -f "${source_path}" || -L "${source_path}" ||
              ! -f "${candidate_path}" || -L "${candidate_path}" ]] ||
            ! /usr/bin/cmp -s "${source_path}" "${candidate_path}"; then
            print -u2 "Refusing missing or modified Xovi notice: ${name}"
            return 1
        fi
    done
    for candidate_path in ${notice_entries}; do
        if (( ${expected_notice_names[(Ie)${candidate_path:t}]} == 0 )); then
            print -u2 "Refusing unexpected Xovi notice: ${candidate_path:t}"
            return 1
        fi
    done
    if [[ ! -f "${third_party_notices_source}" || -L "${third_party_notices_source}" ||
          ! -f "${bundled_third_party_notices}" || -L "${bundled_third_party_notices}" ]] ||
        ! /usr/bin/cmp -s "${third_party_notices_source}" "${bundled_third_party_notices}"; then
        print -u2 "Refusing app without the exact repository third-party notices."
        return 1
    fi

    assert_aarch64_elf "${asset_directory}/rmmirror-transport-wake" 2 "tablet transport executable"
    assert_aarch64_elf "${asset_directory}/rmmirror-probe" 2 "tablet probe executable"
    assert_aarch64_elf "${asset_directory}/rmmirror-files-loopback.so" 3 "Files loopback extension"
}

assert_tablet_prerequisite_assets "${app_path}"

assert_path_absent() {
    local candidate_binary=$1
    local forbidden_path=$2
    local path_label=$3
    local scan_status=0
    LC_ALL=C grep -aFq -- "${forbidden_path}" "${candidate_binary}" 2>/dev/null || scan_status=$?
    case "${scan_status}" in
        0)
            print -u2 "Refusing to package an executable containing the ${path_label}."
            exit 1
            ;;
        1)
            ;;
        *)
            print -u2 "Could not inspect the executable for the ${path_label}."
            exit 1
            ;;
    esac
}

assert_no_local_build_paths() {
    local candidate_binary=$1
    local absolute_derived_data_path=${derived_data_path:a}
    local canonical_derived_data_path=${derived_data_path:A}
    assert_path_absent "${candidate_binary}" "${repository_root}" "repository path"
    assert_path_absent "${candidate_binary}" "${absolute_derived_data_path}" "DerivedData path"
    if [[ "${canonical_derived_data_path}" != "${absolute_derived_data_path}" ]]; then
        assert_path_absent "${candidate_binary}" "${canonical_derived_data_path}" "DerivedData path"
    fi
}

assert_no_local_build_paths "${binary_path}"

architecture_line=$(lipo -archs "${binary_path}")
architecture_values=(${=architecture_line})
if (( ${#architecture_values} == 0 )); then
    print -u2 "The app executable does not report a supported architecture."
    exit 1
fi

typeset -A seen_architectures
for architecture in ${architecture_values}; do
    case "${architecture}" in
        arm64|x86_64)
            ;;
        *)
            print -u2 "The app contains an unsupported architecture: ${architecture}"
            exit 1
            ;;
    esac
    if (( ${+seen_architectures[${architecture}]} )); then
        print -u2 "The app reports a duplicate architecture: ${architecture}"
        exit 1
    fi
    seen_architectures[${architecture}]=1
done

if (( ${#architecture_values} == 1 )); then
    architecture_label=${architecture_values[1]}
elif (( ${#architecture_values} == 2 )) &&
    (( ${+seen_architectures[arm64]} )) &&
    (( ${+seen_architectures[x86_64]} )); then
    architecture_label=universal2
else
    print -u2 "The app contains an unsupported architecture set: ${architecture_line}"
    exit 1
fi

work_directory=$(mktemp -d "${TMPDIR%/}/remarkable-mirror-package.XXXXXX")
trap 'rm -rf -- "${work_directory}"' EXIT
staged_app=${work_directory}/${app_path:t}
ditto "${app_path}" "${staged_app}"

signature_label=unsigned
if signature_details=$(codesign -dv --verbose=2 "${staged_app}" 2>&1); then
    if codesign --verify --deep --strict "${staged_app}" >/dev/null 2>&1; then
        if [[ "${signature_details}" == *"Signature=adhoc"* ]]; then
            signature_label=ad-hoc
        else
            signature_label=signed
        fi
    elif [[ "${signature_details}" == *"Signature=adhoc"* &&
            "${signature_details}" == *"linker-signed"* &&
            "${signature_details}" == *"Info.plist=not bound"* ]]; then
        signature_label=unsigned
    else
        print -u2 "Refusing to package an app with an invalid bundle signature."
        exit 1
    fi
fi

if [[ -n "${signing_identity}" ]]; then
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "${signing_identity}" \
        "${staged_app}"
    codesign --verify --deep --strict --verbose=2 "${staged_app}"
    signature_details=$(codesign -dv --verbose=2 "${staged_app}" 2>&1)
    if [[ "${signature_details}" == *"Signature=adhoc"* ]]; then
        signature_label=ad-hoc
    else
        signature_label=signed
    fi
fi

if [[ -n "${notary_keychain_profile}" ]]; then
    if [[ "${signature_label}" != signed ]]; then
        print -u2 "Notarization requires a valid non-ad-hoc signed app."
        exit 1
    fi
    notary_archive=${work_directory}/notary-submission.zip
    notary_result=${work_directory}/notary-result.plist
    ditto -c -k --sequesterRsrc --keepParent "${staged_app}" "${notary_archive}"
    xcrun notarytool submit \
        "${notary_archive}" \
        --keychain-profile "${notary_keychain_profile}" \
        --wait \
        --timeout 30m \
        --output-format plist > "${notary_result}"
    notary_status=$(plutil -extract status raw -expect string "${notary_result}")
    if [[ "${notary_status}" != Accepted ]]; then
        print -u2 "Apple notarization did not accept the package (status: ${notary_status})."
        exit 1
    fi
    xcrun stapler staple "${staged_app}"
    xcrun stapler validate "${staged_app}"
    signature_label=notarized
fi

package_path=${package_directory}/reMarkable-Mirror-${version}-macOS-${architecture_label}-${signature_label}.zip
mkdir -p "${package_directory}"
ditto -c -k --sequesterRsrc --keepParent "${staged_app}" "${package_path}"

verification_directory=${work_directory}/verification
mkdir -p "${verification_directory}"
ditto -x -k "${package_path}" "${verification_directory}"
verified_app=${verification_directory}/${app_path:t}
verified_identifier=$(plutil -extract CFBundleIdentifier raw -expect string "${verified_app}/Contents/Info.plist")
verified_version=$(plutil -extract CFBundleShortVersionString raw -expect string "${verified_app}/Contents/Info.plist")
verified_build=$(plutil -extract CFBundleVersion raw -expect string "${verified_app}/Contents/Info.plist")
verified_binary_path=${verified_app}/Contents/MacOS/${executable}
verified_architectures=$(lipo -archs "${verified_binary_path}")
if [[ "${verified_identifier}" != "${bundle_identifier}" ||
      "${verified_version}" != "${version}" ||
      "${verified_build}" != "${build_number}" ||
      "${verified_architectures}" != "${architecture_line}" ]]; then
    print -u2 "The packaged app does not match the built bundle identity."
    exit 1
fi
assert_no_local_build_paths "${verified_binary_path}"
assert_tablet_prerequisite_assets "${verified_app}"
if [[ "${signature_label}" == signed || "${signature_label}" == notarized ||
      "${signature_label}" == ad-hoc ]]; then
    codesign --verify --deep --strict "${verified_app}"
fi
if [[ "${signature_label}" == notarized ]]; then
    xcrun stapler validate "${verified_app}"
fi

dmg_source=${work_directory}/dmg
dmg_path=${package_directory}/reMarkable-Mirror-${version}-macOS-${architecture_label}.dmg
mkdir -p "${dmg_source}"
ditto "${staged_app}" "${dmg_source}/${app_path:t}"
ln -s /Applications "${dmg_source}/Applications"
cp "${repository_root}/LICENSE" "${dmg_source}/LICENSE"
rm -f "${dmg_path}"
diskutil image create from \
    --volumeName "reMarkable Mirror" \
    --format UDZO \
    "${dmg_source}" \
    "${dmg_path}" >/dev/null

print "Packaged reMarkable Mirror ${version} (${build_number}) for ${architecture_label}."
print "Bundle identifier: ${bundle_identifier}"
print "Signing status: ${signature_label}"
if [[ -z "${signing_identity}" ]]; then
    print "Developer ID signing hook: skipped (MACOS_SIGNING_IDENTITY is not set)."
fi
if [[ -z "${notary_keychain_profile}" ]]; then
    print "Apple notarization hook: skipped (MACOS_NOTARY_KEYCHAIN_PROFILE is not set)."
fi
print "Package: ${package_path}"
print "Disk image: ${dmg_path}"

shasum -a 256 "${package_path}"
shasum -a 256 "${dmg_path}"
