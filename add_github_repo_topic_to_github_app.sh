#!/bin/bash

# Unset all_repos, mostly useful for local testing re-runs
#unset ALL_REPOS

# Make sure to export all the required vars
#export GITHUB_TOKEN=ghp_1234
#export GITHUB_APP_INSTALLATION_ID=1234
#export GH_ORG=1234
#export TOPIC=xxx

# Check for required variables to be set, and if not present, exit 0
if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_APP_INSTALLATION_ID" ] || [ -z "$GH_ORG" ] || [ -z "$TOPIC" ]; then
  echo "One or more required variables not set, exiting"
  exit 0
fi


###
### Declare functions
###

# Check if hitting API rate-limiting
hold_until_rate_limit_success() {
  
  # Loop forever
  while true; do
    
    # Any call to AWS returns rate limits in the response headers
    API_RATE_LIMIT_UNITS_REMAINING=$(curl -sv \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/$GH_ORG/$GH_REPO/autolinks 2>&1 1>/dev/null \
      | grep -E '< x-ratelimit-remaining' \
      | cut -d ' ' -f 3 \
      | xargs \
      | tr -d '\r')

    # If API rate-limiting is hit, sleep for 1 minute
    if [[ "$API_RATE_LIMIT_UNITS_REMAINING" < 100 ]]; then
      echo "ℹ️  We have less than 100 GitHub API rate-limit tokens left, sleeping for 1 minute"
      sleep 60
    
    # If API rate-limiting shows remaining units, break out of loop and exit function
    else  
      echo ℹ️  Rate limit checked, we have "$API_RATE_LIMIT_UNITS_REMAINING" core tokens remaining so we are continuing
      break
    fi

  done
}

# Get org repos, store in ALL_REPOS var
get_org_repos() {

  ###
  ### Now that we have more than 1k repos, need to use paginated REST call to get all of them (search API hard limit of 1k)
  ###

  # Grab Org info to get repo counts
  ORG_INFO=$(curl -sL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN"\
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/orgs/$GH_ORG)

  # Filter org info to get repo counts
  PRIVATE_REPO_COUNT=$(echo $ORG_INFO | jq -r '.owned_private_repos')
  PUBLIC_REPO_COUNT=$(echo $ORG_INFO | jq -r '.public_repos')
  TOTAL_REPO_COUNT=$(($PRIVATE_REPO_COUNT + $PUBLIC_REPO_COUNT))

  # Calculate number of pages needed to get all repos
  REPOS_PER_PAGE=100
  PAGES_NEEDED=$(($TOTAL_REPO_COUNT / $REPOS_PER_PAGE))
  if [ $(($TOTAL_REPO_COUNT % $REPOS_PER_PAGE)) -gt 0 ]; then
      PAGES_NEEDED=$(($PAGES_NEEDED + 1))
  fi

  # Get all repos
  for PAGE_NUMBER in $(seq $PAGES_NEEDED); do
      echo "Getting repos page $PAGE_NUMBER of $PAGES_NEEDED"
      
      # Could replace this with graphql call (would likely be faster, more efficient), but this works for now
      PAGINATED_REPOS=$(curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN"\
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/$GH_ORG/repos?per_page=$REPOS_PER_PAGE&sort=pushed&page=$PAGE_NUMBER" | jq -r ".[] | select(.topics[] | contains(\"$TOPIC\")) | .name")

      # Combine all pages of repos into one variable
      # Extra return added since last item in list doesn't have newline (would otherwise combine two repos on one line)
      ALL_REPOS="${ALL_REPOS}"$'\n'"${PAGINATED_REPOS}"
  done

  # Find archived repos
  ARCHIVED_REPOS=$(gh repo list $GH_ORG -L 1000 --archived | cut -d "/" -f 2 | cut -f 1)
  ARCHIVED_REPOS_COUNT=$(echo "$ARCHIVED_REPOS" | wc -l | xargs)

  # Remove archived repos from ALL_REPOS
  echo "Skipping $ARCHIVED_REPOS_COUNT archived repos, they are read only"
  for repo in $ARCHIVED_REPOS; do
    ALL_REPOS=$(echo "$ALL_REPOS" | grep -Ev "^$repo$")
  done

  # Remove any empty lines
  ALL_REPOS=$(echo "$ALL_REPOS" | awk 'NF')

  # Get repo count
  ALL_REPOS_COUNT=$(echo "$ALL_REPOS" | wc -l | xargs)
}

###
### Hold any actions until we confirm not rate-limited
###
hold_until_rate_limit_success


###
### Get Org-wide info
###

echo ""
echo "########################################"
echo Getting All Org Repos
echo "########################################"

get_org_repos


###
### Add all repos with that tag to GitHub App
###


# Add all repos in list to the GitHub App
echo ""
echo "########################################"
echo "Iterating through $ALL_REPOS_COUNT repos"
echo "########################################"
echo ""

# Initialize counter var to keep track of repo processing
CURRENT_REPO_COUNT=0

# Iterate over all repos
while IFS=$'\n' read -r GH_REPO; do

  # Echo out some spaces
  echo "###################"
  
  # Hold until rate limit is not hit
  hold_until_rate_limit_success

  # Increment counter
  CURRENT_REPO_COUNT=$((CURRENT_REPO_COUNT + 1))

  # Find github repo ID with REST call
  GH_REPO_ID=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$GH_ORG/$GH_REPO | jq -r '.id')
  
  unset CURL
  CURL=$(curl -L \
    -X PUT \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/user/installations/$GITHUB_APP_INSTALLATION_ID/repositories/$GH_REPO_ID" 2>&1 \
  )
  # Check for errors
  if [[ $(echo "$CURL" | grep -E 'Not Found') ]]; then
    echo "☠️ Something bad happened adding $GH_REPO to Gitub App, please investigate response:"
    echo "$CURL"
  else
    echo "💥 Successfully added $GH_REPO ($CURRENT_REPO_COUNT/$ALL_REPOS_COUNT) to GitHub App w/ ID $GITHUB_APP_INSTALLATION_ID"
  fi

  echo ""

done <<< "$ALL_REPOS"

echo "###################"
echo "Run complete!"
echo "###################"
