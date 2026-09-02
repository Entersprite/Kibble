#!/usr/bin/env bash
# The one place the development signing identity is named.
#
# Why this file exists: build.sh, bootstrap.sh and create-dev-cert.sh each
# named it independently, and two of them agreed on a different name than
# build.sh did. Neither name was a substring of the other, so
# build.sh's `grep -q` failed open and fell back to ad-hoc signing - which
# produces a new code hash every build, which is exactly what makes macOS
# re-prompt for the login password on every Keychain read (see the header of
# create-dev-cert.sh). A silent fallback to the failure mode a script exists
# to prevent is worth one file to make impossible.
#
# Sourced, not executed. It sets one variable and nothing else.

GCHAT_DEV_IDENTITY="GChat Dev"
