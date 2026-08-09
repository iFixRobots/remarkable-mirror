#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
configuration=${CONFIGURATION:-Release}
derived_data_path=${DERIVED_DATA_PATH:-${repository_root}/artifacts/macos/DerivedData}
requested_architectures=${MACOS_ARCHITECTURES:-arm64}
project_path=${repository_root}/mirror/macos/ReMarkableMirror.xcodeproj
launch_services_register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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

if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "The built app has unexpected bundle identifier: ${bundle_identifier}"
    exit 1
fi
if [[ ! -x "${binary_path}" ]]; then
    print -u2 "The built app is missing its executable: ${executable}"
    exit 1
fi

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
