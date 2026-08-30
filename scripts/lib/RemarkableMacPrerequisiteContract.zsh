#!/bin/zsh

rmmirror_is_sha256() {
    (( ${#1} == 64 )) &&
        print -r -- "$1" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{64}$'
}

rmmirror_validate_contract() {
    local contract_path=$1
    local index key value
    local -a lines expected_keys

    if [[ ! -f "${contract_path}" || -L "${contract_path}" ]]; then
        print -u2 "The prerequisite contract is missing or unsafe."
        return 1
    fi
    if [[ $(/usr/bin/wc -l < "${contract_path}") -ne 10 ]]; then
        print -u2 "The prerequisite contract must contain exactly ten newline-terminated fields."
        return 1
    fi

    lines=("${(@f)$(<"${contract_path}")}")
    expected_keys=(
        RMMIRROR_PREREQUISITES_SCHEMA
        RMMIRROR_TABLET_MODEL
        RMMIRROR_TABLET_INSTALL_TARGETS
        RMMIRROR_XOVI_RELEASE
        RMMIRROR_XOVI_ARCHIVE_SHA256
        RMMIRROR_PROBE_VERSION
        RMMIRROR_TRANSPORT_VERSION
        RMMIRROR_TRANSPORT_SCHEMA
        RMMIRROR_USB_CONNECTION_POLICY
        RMMIRROR_REQUIRED_EXTENSIONS
    )
    if (( ${#lines} != ${#expected_keys} )); then
        print -u2 "The prerequisite contract must contain exactly ten fields."
        return 1
    fi

    for (( index = 1; index <= ${#expected_keys}; index++ )); do
        key=${expected_keys[index]}
        if [[ ${lines[index]} != ${key}=* ]]; then
            print -u2 "The prerequisite contract field order changed at ${key}."
            return 1
        fi
        value=${lines[index]#*=}
        if [[ -z "${value}" ]] ||
            ! print -r -- "${lines[index]}" | LC_ALL=C /usr/bin/grep -Eq \
                '^[A-Z][A-Z0-9_]*=[A-Za-z0-9.,/+_-]+$'; then
            print -u2 "The prerequisite contract contains an invalid ${key} value."
            return 1
        fi
    done

    [[ ${lines[1]#*=} == rmmirror.prerequisites/v2 ]] || return 1
    [[ ${lines[2]#*=} == chiappa ]] || return 1
    print -r -- "${lines[3]#*=}" | LC_ALL=C /usr/bin/grep -Eq \
        '^[0-9]+([.][0-9]+){3}[+][0-9]+([.][0-9]+){2}(,[0-9]+([.][0-9]+){3}[+][0-9]+([.][0-9]+){2})*$' || return 1
    print -r -- "${lines[4]#*=}" | LC_ALL=C /usr/bin/grep -Eq '^v[0-9]+-[0-9]{8}$' || return 1
    rmmirror_is_sha256 "${lines[5]#*=}" || return 1
    print -r -- "${lines[6]#*=}" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' || return 1
    print -r -- "${lines[7]#*=}" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' || return 1
    print -r -- "${lines[8]#*=}" | LC_ALL=C /usr/bin/grep -Eq '^rmmirror[.]transport-wake/v[0-9]+$' || return 1
    print -r -- "${lines[9]#*=}" | LC_ALL=C /usr/bin/grep -Eq '^[a-z0-9-]+/v[0-9]+$' || return 1
    [[ ${lines[10]#*=} == framebuffer-spy.so,xovi-message-broker.so,rmmirror-files-loopback.so ]] || return 1
}

rmmirror_contract_value() {
    local contract_path=$1
    local key=$2
    local value
    value=$(/usr/bin/awk -v key="${key}" \
        'index($0, key "=") == 1 { print substr($0, length(key) + 2) }' \
        "${contract_path}")
    if [[ -z "${value}" || "${value}" == *$'\n'* ]]; then
        print -u2 "The prerequisite contract must contain exactly one ${key} value."
        return 1
    fi
    print -r -- "${value}"
}
