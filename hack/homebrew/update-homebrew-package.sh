#!/bin/bash

# Copyright 2021 VMware Tanzu Community Edition contributors. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -o nounset
set -o pipefail
set -o xtrace

version="${1:?TCE version argument empty. Example usage: ./hack/homebrew/update-homebrew-package.sh v0.10.0}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is not set}"

# we only allow this to run from GitHub CI/Action
if [[ "${TCE_CI_BUILD}" != "true" ]]; then
    echo "This is only meant to be run within GitHub Actions CI"
    exit 1
fi

TCE_REPO_RELEASES_URL="https://github.com/vmware-tanzu/community-edition/releases"
TCE_DARWIN_TAR_BALL_FILE="tce-darwin-amd64-${version}.tar.gz"
TCE_LINUX_TAR_BALL_FILE="tce-linux-amd64-${version}.tar.gz"
TCE_CHECKSUMS_FILE="tce-checksums.txt"
TCE_HOMEBREW_TAP_REPO="https://github.com/vmware-tanzu/homebrew-tanzu"

echo "Checking if the necessary files exist for the TCE ${version} release"

wget --spider -q \
    "${TCE_REPO_RELEASES_URL}/download/${version}/${TCE_DARWIN_TAR_BALL_FILE}" > /dev/null || {
        echo "${TCE_DARWIN_TAR_BALL_FILE} is not accessible in TCE ${version} release"
        exit 1
    }

wget --spider -q \
    "${TCE_REPO_RELEASES_URL}/download/${version}/${TCE_LINUX_TAR_BALL_FILE}" > /dev/null || {
        echo "${TCE_LINUX_TAR_BALL_FILE} is not accessible in TCE ${version} release"
        exit 1
    }

wget "${TCE_REPO_RELEASES_URL}/download/${version}/${TCE_CHECKSUMS_FILE}" || {
    echo "${TCE_CHECKSUMS_FILE} is not accessible in TCE ${version} release"
    exit 1
}

darwin_amd64_shasum=$(grep "${TCE_DARWIN_TAR_BALL_FILE}" "${TCE_CHECKSUMS_FILE}" | cut -d ' ' -f1)
linux_amd64_shasum=$(grep "${TCE_LINUX_TAR_BALL_FILE}" "${TCE_CHECKSUMS_FILE}" | cut -d ' ' -f1)
rm -f "${TCE_CHECKSUMS_FILE}"

# clone the homebrew repo
rm -rf "${TCE_HOMEBREW_TAP_REPO}"
git clone --depth 1 --branch main "${TCE_HOMEBREW_TAP_REPO}"

pushd "./homebrew-tanzu" || exit 1

# setup
git config user.name github-actions
git config user.email github-actions@github.com

# which branch did this hash/tag come from
# get commit hash for this tag, then find which branch the hash is on
#
# we need to do this in two stages since we could create a tag on main and then
# create a release branch and tag immediately on that release branch. the new tag would appear in
# both main and this new branch because the commit is the same

# first test the release branch because it gets priority
WHICH_BRANCH=$(git branch -a --contains "${ACTUAL_COMMIT_SHA}" | grep remotes | grep -v -e detached -e HEAD | grep -E "\brelease-[0-9]+\.[0-9]+\b"  | cut -d "/" -f3)
echo "branch: ${WHICH_BRANCH}"
if [[ "${WHICH_BRANCH}" == "" ]]; then
    # now try main since the release branch doesnt exist
    WHICH_BRANCH=$(git branch -a --contains "${ACTUAL_COMMIT_SHA}" | grep remotes | grep -v -e detached -e HEAD | grep -E "\bmain\b"  | cut -d "/" -f3)
    echo "branch: ${WHICH_BRANCH}"
    if [[ "${WHICH_BRANCH}" == "" ]]; then
        echo "Unable to find the branch associated with this hash."
        exit 1
    fi
fi

# make sure we are running on a clean state before checking out
git reset --hard
git fetch
git checkout "${WHICH_BRANCH}"
git pull origin "${WHICH_BRANCH}"


# Replacing old version with the latest stable released version.
sed -i.bak -E "s/version \"v.*/version \"${version}\"/" tanzu-community-edition.rb && rm tanzu-community-edition.rb.bak
# First occurrence of sha256 is for MacOS SHA sum
awk "/sha256 \".*/{c+=1}{if(c==1){sub(\"sha256 \\\".*\",\"sha256 \\\"${darwin_amd64_shasum}\\\"\",\$0)};print}" tanzu-community-edition.rb > tanzu-community-edition-updated.rb
mv tanzu-community-edition-updated.rb tanzu-community-edition.rb
# Second occurrence of sha256 is for Linux SHA sum
awk "/sha256 \".*/{c+=1}{if(c==2){sub(\"sha256 \\\".*\",\"sha256 \\\"${linux_amd64_shasum}\\\"\",\$0)};print}" tanzu-community-edition.rb > tanzu-community-edition-updated.rb
mv tanzu-community-edition-updated.rb tanzu-community-edition.rb


PR_BRANCH="automation-homebrew-${version}"

# now that we are ready... perform the commit
# login
set +x
echo "${GITHUB_TOKEN}" | gh auth login --with-token
set -x

git stash

# create the branch from main or the release branch
DOES_NEW_BRANCH_EXIST=$(git branch -a | grep remotes | grep "${PR_BRANCH}")
echo "does branch exist: ${DOES_NEW_BRANCH_EXIST}"
if [[ "${DOES_NEW_BRANCH_EXIST}" == "" ]]; then
    git checkout -b "${PR_BRANCH}" "${WHICH_BRANCH}"
else
    git checkout "${PR_BRANCH}"
    git rebase -Xtheirs "origin/${WHICH_BRANCH}"
fi

git stash pop

# do the work
git add tanzu-community-edition.rb
git commit -s -m "auto-generated - update tce homebrew formula for version ${version}"
git push origin "${PR_BRANCH}"
gh pr create --repo "${TCE_HOMEBREW_TAP_REPO}" --title "auto-generated - update tce homebrew formula for version ${version}" --body "auto-generated - update tce homebrew formula for version ${version}"
gh pr merge --repo "${TCE_HOMEBREW_TAP_REPO}" "${PR_BRANCH}" --squash --delete-branch --admin

# tag the new dev release
git tag -m "${version}" "${version}"
git push origin "${version}"

popd || exit 1
