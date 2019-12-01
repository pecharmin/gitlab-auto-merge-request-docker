#!/usr/bin/env bash
set -e

if [ -z "$GITLAB_PRIVATE_TOKEN" ]; then
  echo "GITLAB_PRIVATE_TOKEN not set"
  echo "Please set the GitLab Private Token as GITLAB_PRIVATE_TOKEN"
  exit 1
fi

source set-target-branch.sh

# Conditional remove branch after merge
if [ -z "${REMOVE_BRANCH_AFTER_MERGE}" ]; then
  REMOVE_BRANCH_AFTER_MERGE=false
fi

# Conditional squash after merge
if [ -z "${SQUASH}" ]; then
  SQUASH=false
fi

# Conditional auto merge
# if [ -z "${AUTO_MERGE}" ]; then
#   AUTO_MERGE=false
# fi

# Extract the host where the server is running, and add the URL to the APIs
[[ $CI_PROJECT_URL =~ ^https?://[^/]+ ]] && HOST="${BASH_REMATCH[0]}/api/v4/projects/"

if [ -z "$TARGET_BRANCH" ]; then
  echo "TARGET_BRANCH not set"
  if [ -z "$FALLBACK_TARGET_BRANCH" ]; then
    echo "Using Default branch to open the Merge request"
    # Look which is the default branch
    echo "HOST: ${HOST}"
    echo "Project ID: ${CI_PROJECT_ID}"
    TARGET_BRANCH=`curl --silent "${HOST}${CI_PROJECT_ID}" --header "PRIVATE-TOKEN:${GITLAB_PRIVATE_TOKEN}" | jq --raw-output '.default_branch'`
  else
    echo "Using FALLBACK_TARGET_BRANCH branch to open the Merge request"
    TARGET_BRANCH="${FALLBACK_TARGET_BRANCH}"
  fi
fi

for branch in $TARGET_BRANCH
do
	echo
	echo "Source: ${CI_COMMIT_REF_NAME}"
	echo "Target: ${branch}"

	# If Source and Target branch is same then exit.
	if [ "${CI_COMMIT_REF_NAME}" = "${branch}" ]; then
	  echo "Source and Target branch is must be different! Exiting!"
	  continue
	fi

        # Don't create a merge request if latest commit of source branch
        # is already in target branch
        LATEST_SOURCE_COMMIT=`curl --silent "${HOST}${CI_PROJECT_ID}/repository/commits?ref_name=${CI_COMMIT_REF_NAME}" --header "PRIVATE-TOKEN: ${GITLAB_PRIVATE_TOKEN}" | jq '.[0].id'`
        echo "Latest commit in source branch ${CI_COMMIT_REF_NAME}: '$LATEST_SOURCE_COMMIT'"
        if curl --silent "${HOST}${CI_PROJECT_ID}/repository/compare?from=${CI_COMMIT_REF_NAME}&to=${branch}" --header "PRIVATE-TOKEN: ${GITLAB_PRIVATE_TOKEN}" | grep -q "${LATEST_SOURCE_COMMIT}"
        then
          echo "Source branch is already merged into target branch."
          continue
        fi

        # Conditional commit prefix, etc: WIP
        if [ -z "${COMMIT_PREFIX}" ]; then
          COMMIT_TITLE="merge ${CI_COMMIT_REF_NAME} into ${branch}"
        else
          COMMIT_TITLE="${COMMIT_PREFIX}: merge ${CI_COMMIT_REF_NAME} into ${branch}"
        fi

	# The description of our new MR, we want to remove the branch after the MR has
	# been closed
	BODY="{
	    \"id\": ${CI_PROJECT_ID},
	    \"source_branch\": \"${CI_COMMIT_REF_NAME}\",
	    \"target_branch\": \"${branch}\",
	    \"squash\": \"${SQUASH}\",
	    \"title\": \"${COMMIT_TITLE}\",
	    \"assignee_id\":\"${GITLAB_USER_ID}\"
	}"

	# Require a list of all the merge request and take a look if there is already
	# one with the same source branch
	OPEN_MR=`curl --silent "${HOST}${CI_PROJECT_ID}/merge_requests?state=opened" --header "PRIVATE-TOKEN: ${GITLAB_PRIVATE_TOKEN}" | jq ".[] | select(.\"target_branch\"==\"${branch}\") | select(.\"source_branch\"==\"${CI_COMMIT_REF_NAME}\")"`

	# No MR found, let's create a new one
	if [ -n "${OPEN_MR}" ]
	then
	    echo "No MR found, let's create a new one"
	    echo ${BODY}

	    response=`curl --silent -X POST "${HOST}${CI_PROJECT_ID}/merge_requests" \
	            --header "PRIVATE-TOKEN:${GITLAB_PRIVATE_TOKEN}" \
	            --header "Content-Type: application/json" \
	            --data "${BODY}"`

	    echo $response
	    IID=`echo $response | jq .\"iid\"`
	    echo $IID
	    echo "Opened a new merge request: ${COMMIT_TITLE} and assigned with id ${IID}"

	    if $AUTO_MERGE; then
	      BODY="{
	          \"merge_when_pipeline_succeeds\": \"true\",
	          \"squash\": \"${SQUASH}\"
	      }"
	      #\"should_remove_source_branch\": \"${REMOVE_BRANCH_AFTER_MERGE}\",

	      curl --silent -X PUT "${HOST}${CI_PROJECT_ID}/merge_requests/${IID}/merge" \
	            --header "PRIVATE-TOKEN:${GITLAB_PRIVATE_TOKEN}" \
	            --header "Content-Type: application/json" \
	            --data "${BODY}"

	      printf "\n"
	      echo "Auto merging requested for ${COMMIT_TITLE} with id ${IID}"
	    fi

	    continue
	fi

	echo "No new merge request opened"
done
