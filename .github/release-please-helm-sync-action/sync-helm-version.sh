#!/bin/bash

set -euo pipefail

# Script to sync Helm chart appVersion with the app version from release-please manifest

# Ensure all required environment variables are set
if [[ -z "$CHART_PATH" ]]; then
    echo "Error: CHART_PATH environment variable must be set"
    exit 1
fi

if [[ -z "$APP_PATH" ]]; then
    echo "Error: APP_PATH environment variable must be set"
    exit 1
fi

if [[ -z "$HEAD_BRANCH" ]]; then
    echo "Error: HEAD_BRANCH environment variable must be set"
    exit 1
fi

if [[ -z "$BASE_BRANCH" ]]; then
    echo "Error: BASE_BRANCH environment variable must be set"
    exit 1
fi

if [[ -z "$GH_TOKEN" ]]; then
    echo "Error: GH_TOKEN environment variable must be set"
    exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
    echo "Error: GITHUB_REPOSITORY environment variable must be set"
    exit 1
fi

sync_app_version() {
    local version=$(jq -r '."'$APP_PATH'"' .release-please-manifest.json)
    sed -i "s/appVersion:.*/appVersion: $version/" $CHART_PATH/Chart.yaml

    # git diff returns an error if there are unstaged changes
    if git diff --quiet; then
        echo 'App Version already in sync.'
        return 1
    fi

    echo 'App Version needs syncing.'
    return 0
}

bump_helm_version_if_needed() {
    pipx install pybump
    local head_sha=$(gh api '/repos/'$GITHUB_REPOSITORY'/contents/'$CHART_PATH'?ref='$HEAD_BRANCH | jq -r .sha)
    local base_sha=$(gh api '/repos/'$GITHUB_REPOSITORY'/contents/'$CHART_PATH'?ref='$BASE_BRANCH | jq -r .sha)

    if [ "$head_sha" == "$base_sha" ]; then
        echo 'Need to bump Helm chart version as well.'
        pybump bump --file $CHART_PATH/Chart.yaml --level patch
        local helm_version=$(pybump get --file $CHART_PATH/Chart.yaml)
        echo "$(jq '."'$CHART_PATH'"="'$helm_version'"' .release-please-manifest.json)" > .release-please-manifest.json
    else
        echo 'Helm chart version is already being bumped. Only appVersion sync required.'
    fi
}

create_commit() {
    local sha=$(gh api '/repos/'$GITHUB_REPOSITORY'/branches/'$HEAD_BRANCH | jq -r .commit.sha)
    local manifest_b64=$(base64 -w0 -i .release-please-manifest.json)
    local chart_b64=$(base64 -w0 -i $CHART_PATH/Chart.yaml)

    cat $GITHUB_ACTION_PATH/createCommit.json |\
        yq '.variables.input.fileChanges.additions += {"path": ".release-please-manifest.json", "contents": "'$manifest_b64'"}' |\
        yq '.variables.input.fileChanges.additions += {"path": "'$CHART_PATH/Chart.yaml'", "contents": "'$chart_b64'"}' |\
        yq '.variables.input.branch.branchName = "'$HEAD_BRANCH'"' |\
        yq '.variables.input.branch.repositoryNameWithOwner = "'$GITHUB_REPOSITORY'"' |\
        yq '.variables.input.message.headline = "chore: Sync Helm Chart appVersion."' |\
        yq '.variables.input.expectedHeadOid = "'$sha'"' |\
        yq -o json > body.json

    # Using the gh cli produces a VERIFIED commit.
    gh api graphql --input body.json
}

# Main execution
if sync_app_version; then
    echo 'Making commit.'
    bump_helm_version_if_needed
    create_commit
fi
