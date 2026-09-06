#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/branding.sh — single source of truth for product naming.
# Change these two values to re-brand the entire product.
export PRODUCT_NAME="${PRODUCT_NAME:-TaskRamen.ai}"   # user-facing display name
export APP_SLUG="${APP_SLUG:-taskramen}"              # internal slug (paths, identifiers)
