#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# start.sh - container entrypoint: execs the command (bash by default).
# Setup (directories, configs) is done by run-dsp.sh: running
# ./run-dsp.sh is enough, without going through start.sh.
exec "${@:-/bin/bash}"
