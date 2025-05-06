#!/bin/bash

# Docker Cleanup Script
# This script will remove all Docker containers, images, volumes, networks and caches

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Initialize variables
DRY_RUN=false
SKIP_WARNING=false

# Record start time
START_TIME=$(date +%s)

# Function to display usage information
function display_usage {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -d, --dry-run     Run in dry-run mode (show commands without executing)"
  echo "  -y, --yes         Skip the warning prompt (use with caution!)"
  echo "  -h, --help        Display this help message"
  echo ""
  echo "WARNING: This script will remove ALL Docker containers, images, volumes,"
  echo "         networks, and build cache. Use with extreme caution!"
}

# Process command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--yes)
      SKIP_WARNING=true
      shift
      ;;
    -h|--help)
      display_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Error: Unknown option: $1${NC}"
      display_usage
      exit 1
      ;;
  esac
done

# Function to execute or simulate a command based on dry-run flag
function run_cmd {
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY RUN] Would execute: ${NC}$*"
  else
    echo -e "${GREEN}Executing: ${NC}$*"
    eval "$*"
  fi
}

# Display warning unless skipped
if ! $SKIP_WARNING; then
  echo -e "${RED}WARNING: This script will remove ALL Docker resources:${NC}"
  echo " - All containers (running or stopped)"
  echo " - All images (used or unused)"
  echo " - All volumes"
  echo " - All networks"
  echo " - All build cache"
  echo ""
  echo -e "${YELLOW}This action is IRREVERSIBLE and will remove ALL Docker data on this system.${NC}"
  echo ""
  
  if $DRY_RUN; then
    echo -e "${YELLOW}Running in DRY RUN mode. No actual changes will be made.${NC}"
    echo ""
  fi
  
  read -p "Are you sure you want to continue? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
  fi
fi

echo "Starting Docker cleanup..."

# Stop all running containers first
echo -e "\n${GREEN}Stopping all running containers...${NC}"
if $DRY_RUN; then
  echo -e "${YELLOW}[DRY RUN] Would stop all running containers${NC}"
else
  RUNNING_CONTAINERS=$(docker ps -q)
  if [ -n "$RUNNING_CONTAINERS" ]; then
    run_cmd "docker stop $RUNNING_CONTAINERS"
  else
    echo "No running containers found."
  fi
fi

# Remove containers
echo -e "\n${GREEN}Removing all containers...${NC}"
run_cmd "docker container rm -f \$(docker container ls -aq 2>/dev/null) 2>/dev/null || echo 'No containers to remove'"

# Remove images
echo -e "\n${GREEN}Removing all images...${NC}"
run_cmd "docker image rm -f \$(docker image ls -aq 2>/dev/null) 2>/dev/null || echo 'No images to remove'"

# Remove volumes
echo -e "\n${GREEN}Removing all volumes...${NC}"
run_cmd "docker volume rm -f \$(docker volume ls -q 2>/dev/null) 2>/dev/null || echo 'No volumes to remove'"

# Remove networks (except default ones)
echo -e "\n${GREEN}Removing all custom networks...${NC}"
run_cmd "docker network rm \$(docker network ls -q -f type=custom 2>/dev/null) 2>/dev/null || echo 'No custom networks to remove'"

# Prune system (remove all unused data)
echo -e "\n${GREEN}Cleaning up all unused Docker resources...${NC}"
run_cmd "docker system prune -af --volumes"

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
ELAPSED_FORMATTED=$(printf "%02d:%02d:%02d" $((ELAPSED_TIME/3600)) $((ELAPSED_TIME%3600/60)) $((ELAPSED_TIME%60)))

# Final status
if $DRY_RUN; then
  STATUS_MSG="${YELLOW}DRY RUN COMPLETE. No changes were made.${NC}"
  echo -e "\n$STATUS_MSG"
else
  STATUS_MSG="${GREEN}Docker cleanup completed!${NC}"
  echo -e "\n$STATUS_MSG"
fi

# Show remaining resources (if any)
if ! $DRY_RUN; then
  echo -e "\n${GREEN}Current Docker status:${NC}"
  echo -e "\n${YELLOW}Containers:${NC}"
  docker ps -a
  echo -e "\n${YELLOW}Images:${NC}"
  docker images
  echo -e "\n${YELLOW}Volumes:${NC}"
  docker volume ls
  echo -e "\n${YELLOW}Networks:${NC}"
  docker network ls
fi

# Display time elapsed
echo -e "\n${GREEN}Script completed in ${ELAPSED_FORMATTED}.${NC}"

# Send notification if NTFY_TOPIC is set
if [ -n "${NTFY_TOPIC}" ]; then
  echo -e "\n${GREEN}Sending completion notification to topic: ${NTFY_TOPIC}${NC}"
  
  # Notification message
  NOTIFICATION_MSG="Docker cleanup completed in ${ELAPSED_FORMATTED}"
  if $DRY_RUN; then
    NOTIFICATION_MSG="Docker cleanup DRY RUN completed in ${ELAPSED_FORMATTED}"
  fi
  
  # Check if curl is available, otherwise try wget - fail silently if neither exists
  if command -v curl &> /dev/null; then
    run_cmd "curl -s -d \"${NOTIFICATION_MSG}\" \"https://ntfy.sh/${NTFY_TOPIC}\""
  elif command -v wget &> /dev/null; then
    run_cmd "wget -q --post-data=\"${NOTIFICATION_MSG}\" \"https://ntfy.sh/${NTFY_TOPIC}\" -O /dev/null"
  fi
  # Silently fail if neither curl nor wget is available
fi
