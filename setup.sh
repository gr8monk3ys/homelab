#!/bin/bash
# DEPRECATED: This script has been replaced by setup-v2.sh
# The legacy version is preserved at setup.sh.deprecated

set -euo pipefail

echo ""
echo "=============================================="
echo "  WARNING: setup.sh is DEPRECATED"
echo "=============================================="
echo ""
echo "This script has security issues and should not be used."
echo "Please use setup-v2.sh instead, which includes:"
echo ""
echo "  - Proper secret management (no hardcoded passwords)"
echo "  - Version-pinned tool installations"
echo "  - Helm charts and Kustomize overlays"
echo "  - Comprehensive health checks"
echo ""
echo "Usage:"
echo "  ./setup-v2.sh"
echo ""
echo "Or with environment configuration:"
echo "  ENVIRONMENT=production DOMAIN=yourdomain.com ./setup-v2.sh"
echo ""
echo "The legacy script is preserved at: setup.sh.deprecated"
echo ""

read -p "Do you want to run setup-v2.sh instead? [Y/n] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    exec ./setup-v2.sh "$@"
else
    echo "Exiting. Run ./setup-v2.sh when ready."
    exit 1
fi
