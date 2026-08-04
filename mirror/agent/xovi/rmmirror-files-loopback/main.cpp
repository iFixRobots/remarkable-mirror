// SPDX-License-Identifier: GPL-3.0-only
//
// Derived from the native interface hooks in asivery/rm-xovi-extensions'
// webserver-remote extension. This variant deliberately contains no QML
// injection, notification UI, authorization broker, LAN listener, or proxy.

#include <QNetworkInterface>
#include <QString>

#include "xovi.h"

extern "C" {
QNetworkInterface override$_ZN17QNetworkInterface17interfaceFromNameERK7QString(
    QString const& name) {
    if (name == "usb0" || name == "usb1") {
        QString loopback("lo");
        return $_ZN17QNetworkInterface17interfaceFromNameERK7QString(&loopback);
    }
    return $_ZN17QNetworkInterface17interfaceFromNameERK7QString(&name);
}

bool override$_ZNK12QHostAddress8isGlobalEv(QHostAddress* address) {
    if (address->isLoopback()) {
        return true;
    }
    return $_ZNK12QHostAddress8isGlobalEv(address);
}

void _xovi_construct() {}
}
