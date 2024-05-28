#!/bin/bash -eu

apt-cache policy "$1" | grep 'Installed:' | grep -v '(none)' > /dev/null
