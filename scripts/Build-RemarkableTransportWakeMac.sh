#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
source_directory=${repository_root}/mirror/agent
package=./cmd/rmmirror-transport-wake
binary_name=rmmirror-transport-wake
expected_go_version='go version go1.26.5 darwin/arm64'

if (( $# != 1 )); then
    print -u2 "Usage: ${0:t} /absolute/output/path/rmmirror-transport-wake"
    exit 64
fi

output_path=$1
if [[ "${output_path}" != /* ]]; then
    print -u2 "The output path must be absolute."
    exit 64
fi
if [[ "${output_path:t}" != "${binary_name}" ]]; then
    print -u2 "The output filename must be ${binary_name}."
    exit 64
fi
if [[ -L "${output_path}" || ( -e "${output_path}" && ! -f "${output_path}" ) ]]; then
    print -u2 "Refusing unsafe output path: ${output_path}"
    exit 1
fi

go_command=$(command -v go || true)
if [[ -z "${go_command}" || ! -x "${go_command}" ]]; then
    print -u2 "Go was not found in PATH."
    exit 1
fi
actual_go_version=$("${go_command}" version)
if [[ "${actual_go_version}" != "${expected_go_version}" ]]; then
    print -u2 "This verified build requires '${expected_go_version}'; found '${actual_go_version}'."
    exit 1
fi
if [[ ! -f "${source_directory}/go.mod" || -L "${source_directory}/go.mod" ]]; then
    print -u2 "The tablet agent module is missing or unsafe: ${source_directory}/go.mod"
    exit 1
fi

assert_static_aarch64_elf() {
    local candidate=$1
    local raw
    local -a bytes machine_bytes offset_bytes entry_size_bytes count_bytes type_bytes
    local machine program_header_offset program_header_entry_size program_header_count
    local file_size entry_offset program_header_type index

    if [[ ! -f "${candidate}" || -L "${candidate}" ]]; then
        print -u2 "Build output is missing or unsafe: ${candidate}"
        return 1
    fi
    file_size=$(/usr/bin/stat -f '%z' "${candidate}")
    if (( file_size < 64 )); then
        print -u2 "Build output is too small to be an ELF file."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 0 -N 7 "${candidate}")
    bytes=(${=raw})
    if (( ${#bytes} != 7 )) ||
        (( bytes[1] != 127 || bytes[2] != 69 || bytes[3] != 76 || bytes[4] != 70 )); then
        print -u2 "Build output is not an ELF file."
        return 1
    fi
    if (( bytes[5] != 2 || bytes[6] != 1 || bytes[7] != 1 )); then
        print -u2 "Build output is not 64-bit little-endian ELF."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 18 -N 2 "${candidate}")
    machine_bytes=(${=raw})
    if (( ${#machine_bytes} != 2 )); then
        print -u2 "Build output has a truncated ELF machine field."
        return 1
    fi
    machine=$(( machine_bytes[1] | (machine_bytes[2] << 8) ))
    if (( machine != 183 )); then
        print -u2 "Build output has ELF machine ${machine} instead of AArch64 183."
        return 1
    fi

    raw=$(/usr/bin/od -An -v -tu1 -j 32 -N 8 "${candidate}")
    offset_bytes=(${=raw})
    if (( ${#offset_bytes} != 8 )) ||
        (( offset_bytes[5] != 0 || offset_bytes[6] != 0 || offset_bytes[7] != 0 || offset_bytes[8] != 0 )); then
        print -u2 "Build output has an unsupported ELF program-header offset."
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
        print -u2 "Build output has a truncated ELF program-header table."
        return 1
    fi
    program_header_entry_size=$(( entry_size_bytes[1] | (entry_size_bytes[2] << 8) ))
    program_header_count=$(( count_bytes[1] | (count_bytes[2] << 8) ))
    if (( program_header_entry_size != 56 || program_header_count == 0 || program_header_count > 256 )); then
        print -u2 "Build output has an invalid ELF program-header table."
        return 1
    fi
    if (( program_header_offset < 64 ||
          program_header_offset + (program_header_entry_size * program_header_count) > file_size )); then
        print -u2 "Build output has an out-of-bounds ELF program-header table."
        return 1
    fi

    for (( index = 0; index < program_header_count; index++ )); do
        entry_offset=$(( program_header_offset + (index * program_header_entry_size) ))
        raw=$(/usr/bin/od -An -v -tu1 -j ${entry_offset} -N 4 "${candidate}")
        type_bytes=(${=raw})
        if (( ${#type_bytes} != 4 )); then
            print -u2 "Build output has a truncated ELF program header."
            return 1
        fi
        program_header_type=$((
            type_bytes[1] |
            (type_bytes[2] << 8) |
            (type_bytes[3] << 16) |
            (type_bytes[4] << 24)
        ))
        if (( program_header_type == 3 )); then
            print -u2 "Build output unexpectedly depends on a dynamic ELF interpreter."
            return 1
        fi
    done
}

build_root=$(mktemp -d "${TMPDIR:-/tmp}/remarkable-transport-wake-build.XXXXXX")
publish_temporary_path=
cleanup() {
    if [[ -n "${publish_temporary_path}" && -e "${publish_temporary_path}" ]]; then
        /bin/rm -f -- "${publish_temporary_path}"
    fi
    /bin/rm -rf -- "${build_root}"
}
trap cleanup EXIT

first_cache=${build_root}/cache-first
first_module_cache=${build_root}/module-cache-first
second_cache=${build_root}/cache-second
second_module_cache=${build_root}/module-cache-second
first_build=${build_root}/${binary_name}.first
second_build=${build_root}/${binary_name}.second
/bin/mkdir -p \
    "${first_cache}" \
    "${first_module_cache}" \
    "${second_cache}" \
    "${second_module_cache}"

build_once() {
    local cache=$1
    local module_cache=$2
    local destination=$3

    (
        cd "${source_directory}"
        /usr/bin/env \
            GOOS=linux \
            GOARCH=arm64 \
            CGO_ENABLED=0 \
            GOTOOLCHAIN=local \
            GOWORK=off \
            GOENV=off \
            GOFLAGS= \
            GOEXPERIMENT= \
            GOARM64=v8.0 \
            GOPROXY=off \
            GOSUMDB=off \
            GOCACHE="${cache}" \
            GOMODCACHE="${module_cache}" \
            "${go_command}" build \
                -a \
                -mod=readonly \
                -trimpath \
                -buildvcs=false \
                '-ldflags=-s -w -buildid=' \
                -o "${destination}" \
                "${package}"
    )
}

build_once "${first_cache}" "${first_module_cache}" "${first_build}"
build_once "${second_cache}" "${second_module_cache}" "${second_build}"
assert_static_aarch64_elf "${first_build}"
assert_static_aarch64_elf "${second_build}"

first_hash=$(/usr/bin/shasum -a 256 "${first_build}" | /usr/bin/awk '{print $1}')
second_hash=$(/usr/bin/shasum -a 256 "${second_build}" | /usr/bin/awk '{print $1}')
if [[ "${first_hash}" != "${second_hash}" ]] || ! /usr/bin/cmp -s "${first_build}" "${second_build}"; then
    print -u2 "The two isolated builds produced different output."
    exit 1
fi

output_directory=${output_path:h}
/bin/mkdir -p "${output_directory}"
if [[ -L "${output_directory}" || ! -d "${output_directory}" ]]; then
    print -u2 "Refusing unsafe output directory: ${output_directory}"
    exit 1
fi
publish_temporary_path=$(mktemp "${output_directory}/.${binary_name}.XXXXXX")
/bin/cp -f "${first_build}" "${publish_temporary_path}"
/bin/chmod 0755 "${publish_temporary_path}"
published_hash=$(/usr/bin/shasum -a 256 "${publish_temporary_path}" | /usr/bin/awk '{print $1}')
if [[ "${published_hash}" != "${first_hash}" ]]; then
    print -u2 "Published binary hash does not match the verified build."
    exit 1
fi
/bin/mv -f "${publish_temporary_path}" "${output_path}"
publish_temporary_path=

print "Built deterministic Linux ARM64 ${binary_name}."
print "Go toolchain: ${actual_go_version}"
print "SHA-256: ${first_hash}"
print "Output: ${output_path}"
