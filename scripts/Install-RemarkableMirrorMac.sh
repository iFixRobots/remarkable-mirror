#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
configuration=${CONFIGURATION:-Release}
derived_data_path=${DERIVED_DATA_PATH:-${repository_root}/artifacts/macos/DerivedData}
source_app=${derived_data_path}/Build/Products/${configuration}/reMarkable\ Mirror.app
install_directory=${MACOS_INSTALL_DIRECTORY:-${HOME}/Applications}
installed_app=${install_directory}/${source_app:t}
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

if [[ ! -d "${source_app}" ]]; then
    print -u2 "Build the app first with scripts/Build-RemarkableMirrorMac.sh."
    exit 1
fi
if [[ ! -x "${launch_services_register}" ]]; then
    print -u2 "LaunchServices registration tool was not found at ${launch_services_register}."
    exit 1
fi

info_plist=${source_app}/Contents/Info.plist
bundle_identifier=$(plutil -extract CFBundleIdentifier raw -expect string "${info_plist}")
version=$(plutil -extract CFBundleShortVersionString raw -expect string "${info_plist}")
build_number=$(plutil -extract CFBundleVersion raw -expect string "${info_plist}")
executable=$(plutil -extract CFBundleExecutable raw -expect string "${info_plist}")
binary_path=${source_app}/Contents/MacOS/${executable}

if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "Refusing to install unexpected bundle identifier: ${bundle_identifier}"
    exit 1
fi
if [[ ! -x "${binary_path}" ]]; then
    print -u2 "The app is missing its executable: ${executable}"
    exit 1
fi
architectures=$(lipo -archs "${binary_path}")

signature_label=unsigned
if signature_details=$(codesign -dv --verbose=2 "${source_app}" 2>&1); then
    if codesign --verify --deep --strict "${source_app}" >/dev/null 2>&1; then
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
        print -u2 "Refusing to install an app with an invalid bundle signature."
        exit 1
    fi
fi

if [[ -e "${installed_app}" ]]; then
    print -u2 "Refusing to replace the existing app at ${installed_app}."
    print -u2 "Move that app aside explicitly, then rerun this installer."
    exit 1
fi

mkdir -p "${install_directory}"
ditto "${source_app}" "${installed_app}"

installed_identifier=$(plutil -extract CFBundleIdentifier raw -expect string "${installed_app}/Contents/Info.plist")
installed_version=$(plutil -extract CFBundleShortVersionString raw -expect string "${installed_app}/Contents/Info.plist")
installed_build=$(plutil -extract CFBundleVersion raw -expect string "${installed_app}/Contents/Info.plist")
installed_architectures=$(lipo -archs "${installed_app}/Contents/MacOS/${executable}")
if [[ "${installed_identifier}" != "${bundle_identifier}" ||
      "${installed_version}" != "${version}" ||
      "${installed_build}" != "${build_number}" ||
      "${installed_architectures}" != "${architectures}" ]]; then
    print -u2 "The installed app does not match the built bundle identity."
    exit 1
fi
if [[ "${signature_label}" != unsigned ]]; then
    codesign --verify --deep --strict "${installed_app}"
fi

"${launch_services_register}" -f "${installed_app}"

print "Installed reMarkable Mirror ${version} (${build_number}) for ${architectures}."
print "Bundle identifier: ${bundle_identifier}"
print "Signing status: ${signature_label}"
print "LaunchServices registration: refreshed for installed app"
print "Local review app: ${installed_app}"
