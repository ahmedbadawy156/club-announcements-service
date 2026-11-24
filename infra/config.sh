# Shared settings for the infra scripts. Sourced, not run.
# Nothing here is secret: Floci uses the fake account 000000000000.

export AWS_PROFILE="${AWS_PROFILE:-floci}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1   # stop Git Bash turning /api/... into Windows paths

# Use the AWS CLI from PATH, or the default Windows install location.
if command -v aws >/dev/null 2>&1; then
  AWS=aws
elif [ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]; then
  AWS="/c/Program Files/Amazon/AWSCLIV2/aws.exe"
else
  echo "AWS CLI not found. Install AWS CLI v2 and open a new terminal." >&2
  exit 1
fi

ACCOUNT=000000000000
REGION=us-east-1

FUNCTION=club-announcements-api
ROLE=club-announcements-role
ROLE_POLICY=club-announcements-access
API_NAME=club-announcements-http-api
LOG_GROUP=/aws/lambda/$FUNCTION

# The Membership service issues the login tokens. deploy.sh reads its API
# address from here to fetch the PUBLIC key (team guide, Section 8).
MEMBERSHIP_DIR="${MEMBERSHIP_DIR:-../club-membership-service}"

# Website origins allowed by CORS. On Floci the S3 website is served from
# http://localhost:4566.
CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:4566}"

# Address of an API on Floci (works while the PC can resolve localhost.floci.io).
api_url() { echo "http://$1.execute-api.localhost.floci.io:4566"; }
