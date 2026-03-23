#!/usr/bin/env bash
# Fetch unresolved PR review threads via GitHub GraphQL API
# Usage: fetch-threads.sh <PR_NUMBER>
set -euo pipefail

PR=${1:?Usage: fetch-threads.sh <PR_NUMBER>}

# Detect owner/repo from current git remote
REPO_SLUG=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
OWNER=${REPO_SLUG%%/*}
REPO=${REPO_SLUG##*/}

gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        title
        author { login }
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 10) {
              nodes {
                id
                databaseId
                body
                path
                line
                startLine
                author { login }
                createdAt
              }
            }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR"
