#!/bin/bash

# Source the modules
source "scripts/modules/config.sh"
source "scripts/modules/utils.sh"
source "scripts/modules/iam.sh"

# Call the setup_iam_role function
setup_iam_role
