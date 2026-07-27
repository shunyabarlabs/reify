// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module app;

import reify.app : runNavokojApp;
import reify.document : documentApp;

int main(string[] args) {
    return runNavokojApp(documentApp(), args);
}