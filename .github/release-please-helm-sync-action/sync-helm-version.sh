#!/bin/bash

set -euo pipefail

# Script to sync Helm chart appVersion with the app version from release-please manifest

# Ensure all required environment variables are set
if [[ -z "${CHART_PATH:-}" ]]; then
    echo "Error: CHART_PATH environment variable must be set"
    exit 1
fi

if [[ -z "${APP_PATH:-}" ]]; then
    echo "Error: APP_PATH environment variable must be set"
    exit 1
fi

if [[ -z "${HEAD_BRANCH:-}" ]]; then
    echo "Error: HEAD_BRANCH environment variable must be set"
    exit 1
fi

if [[ -z "${BASE_BRANCH:-}" ]]; then
    echo "Error: BASE_BRANCH environment variable must be set"
    exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "Error: GH_TOKEN environment variable must be set"
    exit 1
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "Error: GITHUB_REPOSITORY environment variable must be set"
    exit 1
fi

VERSION=$(jq -r '."'$APP_PATH'"' .release-please-manifest.json)
sed -i "s/appVersion:.*/appVersion: $VERSION/" $CHART_PATH/Chart.yaml

# git diff returns an error if there are unstaged changes
if git diff --quiet; then
    echo 'App Version already in sync.'
    echo 'changed=false' >> $GITHUB_OUTPUT
else
    echo 'App Version needs syncing. Making commit.'
    pipx install pybump
    HEAD_SHA=$(gh api '/repos/'$GITHUB_REPOSITORY'/branches/'$HEAD_BRANCH | jq -r .commit.sha)
    BASE_SHA=$(gh api '/repos/'$GITHUB_REPOSITORY'/branches/'$BASE_BRANCH | jq -r .commit.sha)
    if [ "$HEAD_SHA" == "$BASE_SHA" ]; then
        echo 'Helm chart version is already being bumped. Only appVersion sync required.'
    else
        echo 'Need to bump Helm chart version as well.'
        pybump bump --file $CHART_PATH/Chart.yaml --level patch
        HELM_VERSION=$(pybump get --file $CHART_PATH/Chart.yaml)
        echo "$(jq '."'$CHART_PATH'"="'$HELM_VERSION'"' .release-please-manifest.json)" > .release-please-manifest.json
    fi
    echo 'changed=true' >> $GITHUB_OUTPUT
fi

# Create PR if changes were made
if [[ "${GITHUB_OUTPUT:-}" == *"changed=true"* ]]; then
    SHA=$(gh api '/repos/'$GITHUB_REPOSITORY'/branches/'$HEAD_BRANCH | jq -r .commit.sha)
    MANIFEST_B64=$(base64 -w0 -i .release-please-manifest.json)
    CHART_B64=$(base64 -w0 -i $CHART_PATH/Chart.yaml)
    cat $GITHUB_ACTION_PATH/createCommit.json |\
        yq '.variables.input.fileChanges.additions += {"path": ".release-please-manifest.json", "contents": "'$MANIFEST_B64'"}' |\
        yq '.variables.input.fileChanges.additions += {"path": "'$CHART_PATH/Chart.yaml'", "contents": "'$CHART_B64'"}' |\
        yq '.variables.input.branch.branchName = "'$HEAD_BRANCH'"' |\
        yq '.variables.input.branch.repositoryNameWithOwner = "'$GITHUB_REPOSITORY'"' |\
        yq '.variables.input.message.headline = "chore: Sync Helm Chart appVersion."' |\
        yq '.variables.input.expectedHeadOid = "'$SHA'"' |\
        yq -o json > body.json

    # Using the gh cli produces a VERIFIED commit.
    gh api graphql --input body.json
fi