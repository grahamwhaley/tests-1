#!/bin/bash
#
# Copyright (c) 2017-2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

export KATA_RUNTIME=${KATA_RUNTIME:-kata-runtime}

# If we fail for any reason a message will be displayed
die(){
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

info() {
	echo -e "INFO: $*"
}

function clone_and_build() {
	github_project="$1"
	make_target="$2"
	project_dir="${GOPATH}/src/${github_project}"

	echo "Retrieve repository ${github_project}"
	go get -d ${github_project} || true

	# fixme: once tool to parse and get branches from github is
	# completed, add it here to fetch branches under testing

	pushd ${project_dir}

	# Override branch if we are testing a PR.
	[ -z "$pr_number" ] || branch="${target_branch}"
	if [ "$kata_repo" != "$github_project" ]; then
		current_branch=$(git rev-parse --abbrev-ref HEAD)
		# check if we are on a branch created by the
		# Depends-on feature.
		if echo "${current_branch}" | egrep "p[0-9]+" > /dev/null; then
			echo "already in the correct branch"
		else
			git fetch origin && git checkout "${branch}"
		fi

	fi

	echo "Build ${github_project}"
	if [ ! -f Makefile ]; then
		echo "Run autogen.sh to generate Makefile"
		bash -f autogen.sh
	fi

	make

	popd
}

function clone_build_and_install() {
	clone_and_build $1 $2
	pushd "${GOPATH}/src/${1}"
	echo "Install repository ${1}"
	sudo -E PATH=$PATH KATA_RUNTIME=${KATA_RUNTIME} make install
	popd
}

function install_yq() {
	GOPATH=${GOPATH:-${HOME}/go}
	local yq_path="${GOPATH}/bin/yq"
	local yq_pkg="github.com/mikefarah/yq"
	[ -x  "${GOPATH}/bin/yq" ] && return

	read -r -a sysInfo <<< "$(uname -sm)"

	case "${sysInfo[0]}" in
	"Linux" | "Darwin")
		goos="${sysInfo[0],}"
		;;
	"*")
		die "OS ${sysInfo[0]} not supported"
		;;
	esac

	case "${sysInfo[1]}" in
	"aarch64")
		goarch=arm64
		;;
	"x86_64")
		goarch=amd64
		;;
	"s390x")
		goarch=s390x
		;;
	"*")
		die "Arch ${sysInfo[1]} not supported"
		;;
	esac

	mkdir -p "${GOPATH}/bin"

	# Workaround to get latest release from github (to not use github token).
	# Get the redirection to latest release on github.
	yq_latest_url=$(curl -Ls -o /dev/null -w %{url_effective} "https://${yq_pkg}/releases/latest")
	# The redirected url should include the latest release version
	# https://github.com/mikefarah/yq/releases/tag/<VERSION-HERE>
	yq_version=$(basename "${yq_latest_url}")

	local yq_url="https://${yq_pkg}/releases/download/${yq_version}/yq_${goos}_${goarch}"
	curl -o "${yq_path}" -L ${yq_url}
	chmod +x ${yq_path}

	if ! command -v "${yq_path}" >/dev/null; then
		die "Cannot not get ${yq_path} executable"
	fi
}

function get_version(){
	dependency="$1"
	GOPATH=${GOPATH:-${HOME}/go}
	# This is needed in order to retrieve the version for qemu-lite
	install_yq >&2
	runtime_repo="github.com/kata-containers/runtime"
	runtime_repo_dir="$GOPATH/src/${runtime_repo}"
	versions_file="${runtime_repo_dir}/versions.yaml"
	mkdir -p "$(dirname ${runtime_repo_dir})"
	[ -d "${runtime_repo_dir}" ] ||  git clone --quiet https://${runtime_repo}.git "${runtime_repo_dir}"
	[ ! -f "$versions_file" ] && { echo >&2 "ERROR: cannot find $versions_file"; exit 1; }
	result=$("${GOPATH}/bin/yq" read "$versions_file" "$dependency")
	[ "$result" = "null" ] && result=""
	echo "$result"
}

function check_gopath() {
	# Verify GOPATH is set
	if [ -z "$GOPATH" ]; then
		export GOPATH=$(go env GOPATH)
	fi
}

function apply_depends_on() {
	pushd "${GOPATH}/src/${kata_repo}"
	label_lines=$(git log --format=%s%b master.. | grep "Depends-on:" || true)
	if [ "${label_lines}" == "" ]; then
		popd
		return 0
	fi

	nb_lines=$(echo "${label_lines}" | wc -l)

	repos_found=()
	for i in $(seq 1 "${nb_lines}")
	do
		label_line=$(echo "${label_lines}" | sed "${i}q;d")
		label_str=$(echo "${label_line}" | cut -d ':' -f2)
		repo=$(echo "${label_str}" | tr -d '[:space:]' | cut -d'#' -f1)
		if [[ "${repos_found[@]}" =~ "${repo}" ]]; then
			echo "Repository $repo was already defined in a 'Depends-on:' tag."
			echo "Only one repository per tag is allowed."
			return 1
		fi
		repos_found+=("$repo")
		pr_id=$(echo "${label_str}" | cut -d'#' -f2)

		echo "This PR depends on repository: ${repo} and pull request: ${pr_id}"
		if [ ! -d "${GOPATH}/src/${repo}" ]; then
			go get -d "$repo" || true
		fi

		pushd "${GOPATH}/src/${repo}"
		echo "Fetching pull request: ${pr_id} for repository: ${repo}"
		pr_branch="p${pr_id}"
		git fetch origin "pull/${pr_id}/head:${pr_branch}" && \
			git checkout "${pr_branch}" && \
			git rebase "origin/${target_branch}"
		popd
	done

	popd
}

function waitForProcess(){
        wait_time="$1"
        sleep_time="$2"
        cmd="$3"
        while [ "$wait_time" -gt 0 ]; do
                if eval "$cmd"; then
                        return 0
                else
                        sleep "$sleep_time"
                        wait_time=$((wait_time-sleep_time))
                fi
        done
        return 1
}
