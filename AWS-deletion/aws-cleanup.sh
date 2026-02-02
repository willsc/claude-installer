#!/bin/bash

# AWS Instance Termination & Cleanup Script
# This script terminates an EC2 instance and its associated resources:
# 1. Terminates the instance
# 2. Deletes the corresponding Elastic Network Interfaces (ENIs)
# 3. Deletes the corresponding EBS volumes
# 4. Cancels the corresponding capacity reservation (if needed)

# Configuration
INSTANCE_ID=""  # Set your instance ID here, or pass as argument
DRY_RUN=false   # Set to true for dry run mode
REGION="us-east-1"  # Default region
PROFILE="default"   # AWS CLI profile

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${GREEN}==>${NC} $1"; }

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -p|--profile)
            PROFILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 -i <instance-id> [--dry-run] [--region <region>] [--profile <profile>]"
            echo "Example: $0 -i i-1234567890abcdef0 --dry-run"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Check if instance ID is provided
if [[ -z "$INSTANCE_ID" ]]; then
    echo "Usage: $0 -i <instance-id> [--dry-run] [--region <region>] [--profile <profile>]"
    echo "Example: $0 -i i-1234567890abcdef0 --dry-run"
    exit 1
fi

# Check prerequisites before doing anything else
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq is not installed. Please install it first (brew install jq / apt-get install jq)."
    exit 1
fi

# Function to run AWS EC2 commands
aws_ec2() {
    aws ec2 --region "$REGION" --profile "$PROFILE" "$@"
}

# Function to run AWS command with dry run check
run_aws_command() {
    local desc="$1"
    shift
    
    log_info "$desc"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would execute: aws ec2 --region $REGION --profile $PROFILE $*"
        return 0
    fi
    
    if ! aws_ec2 "$@"; then
        log_error "AWS CLI command failed: $*"
        return 1
    fi
}

# Main execution
main() {
    log_step "Starting AWS Resource Cleanup for Instance: $INSTANCE_ID"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY RUN MODE - No resources will be modified"
    fi
    
    # Step 1: Check if instance exists and get details
    log_step "1. Checking instance details"
    
    local instance_info
    if ! instance_info=$(aws_ec2 describe-instances --instance-ids "$INSTANCE_ID" 2>&1); then
        log_error "Instance $INSTANCE_ID not found or you don't have permission to access it"
        log_error "AWS error: $instance_info"
        exit 1
    fi
    
    # Check if reservations array is empty or instance doesn't exist
    local instance_count
    instance_count=$(echo "$instance_info" | jq -r '.Reservations | length')
    if [[ "$instance_count" -eq 0 ]]; then
        log_error "Instance $INSTANCE_ID not found"
        exit 1
    fi
    
    # Extract instance details
    local instance_state instance_type
    instance_state=$(echo "$instance_info" | jq -r '.Reservations[0].Instances[0].State.Name')
    instance_type=$(echo "$instance_info" | jq -r '.Reservations[0].Instances[0].InstanceType')
    
    log_info "Instance State: $instance_state"
    log_info "Instance Type: $instance_type"
    
    # Check if already terminated
    if [[ "$instance_state" == "terminated" ]]; then
        log_warn "Instance is already terminated"
        exit 0
    fi
    
    # Check for termination protection
    local termination_protection
    termination_protection=$(aws_ec2 describe-instance-attribute \
        --instance-id "$INSTANCE_ID" \
        --attribute disableApiTermination \
        --query 'DisableApiTermination.Value' \
        --output text 2>/dev/null) || termination_protection="false"
    
    if [[ "$termination_protection" == "true" ]]; then
        log_error "Instance has termination protection enabled. Disable it first using:"
        echo "  aws ec2 --region $REGION --profile $PROFILE modify-instance-attribute --instance-id $INSTANCE_ID --no-disable-api-termination"
        exit 1
    fi
    
    # Step 2: Get associated resources before termination
    log_step "2. Discovering associated resources"
    
    # Get ENI(s) attached to the instance - handle empty arrays properly
    local eni_ids_raw eni_ids
    eni_ids_raw=$(echo "$instance_info" | jq -r '.Reservations[0].Instances[0].NetworkInterfaces[]?.NetworkInterfaceId // empty')
    eni_ids=$(echo "$eni_ids_raw" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
    
    # Get EBS volumes attached to the instance
    local volume_ids_raw volume_ids
    volume_ids_raw=$(echo "$instance_info" | jq -r '.Reservations[0].Instances[0].BlockDeviceMappings[]?.Ebs.VolumeId // empty')
    volume_ids=$(echo "$volume_ids_raw" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
    
    # Check capacity reservation
    local capacity_reservation_id
    capacity_reservation_id=$(echo "$instance_info" | jq -r '.Reservations[0].Instances[0].CapacityReservationId // empty')
    
    log_info "Found ENIs: ${eni_ids:-None}"
    log_info "Found Volumes: ${volume_ids:-None}"
    log_info "Capacity Reservation: ${capacity_reservation_id:-None}"
    
    # Ask for confirmation (unless in dry run mode)
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "\n${YELLOW}WARNING: This will permanently delete resources:${NC}"
        echo "  - Instance: $INSTANCE_ID"
        [[ -n "$eni_ids" ]] && echo "  - ENIs: $eni_ids"
        [[ -n "$volume_ids" ]] && echo "  - Volumes: $volume_ids"
        [[ -n "$capacity_reservation_id" ]] && echo "  - Capacity Reservation: $capacity_reservation_id"
        
        echo ""
        read -r -p "Are you sure you want to proceed? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log_info "Operation cancelled"
            exit 0
        fi
    fi
    
    # Step 3: Terminate the instance
    log_step "3. Terminating instance $INSTANCE_ID"
    if ! run_aws_command "Terminating instance..." terminate-instances --instance-ids "$INSTANCE_ID"; then
        log_error "Failed to terminate instance"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == false ]]; then
        # Wait for instance to terminate
        log_info "Waiting for instance to terminate (this may take a few minutes)..."
        if ! aws_ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"; then
            log_error "Timed out waiting for instance to terminate"
            exit 1
        fi
        log_info "Instance terminated successfully"
    fi
    
    # Step 4: Delete ENIs (if any remain after termination)
    log_step "4. Checking for remaining ENIs"
    if [[ -n "$eni_ids" ]]; then
        for eni_id in $eni_ids; do
            # Check if ENI still exists (it may have been deleted with the instance)
            local eni_info
            if ! eni_info=$(aws_ec2 describe-network-interfaces --network-interface-ids "$eni_id" 2>/dev/null); then
                log_info "ENI $eni_id no longer exists (deleted with instance)"
                continue
            fi
            
            local eni_status
            eni_status=$(echo "$eni_info" | jq -r '.NetworkInterfaces[0].Status')
            
            if [[ "$eni_status" == "available" ]]; then
                run_aws_command "Deleting ENI: $eni_id" delete-network-interface --network-interface-id "$eni_id" || \
                    log_warn "Failed to delete ENI $eni_id - may require manual cleanup"
            else
                log_info "ENI $eni_id is in status '$eni_status' - skipping"
            fi
        done
    else
        log_info "No ENIs to check"
    fi
    
    # Step 5: Delete EBS volumes (if any remain after termination)
    log_step "5. Checking for remaining EBS volumes"
    if [[ -n "$volume_ids" ]]; then
        # Give AWS a moment to process volume deletions from instance termination
        [[ "$DRY_RUN" == false ]] && sleep 5
        
        for volume_id in $volume_ids; do
            # Check if volume still exists
            local volume_info
            if ! volume_info=$(aws_ec2 describe-volumes --volume-ids "$volume_id" 2>/dev/null); then
                log_info "Volume $volume_id no longer exists (deleted with instance)"
                continue
            fi
            
            local volume_state
            volume_state=$(echo "$volume_info" | jq -r '.Volumes[0].State')
            
            if [[ "$volume_state" == "available" ]]; then
                run_aws_command "Deleting volume: $volume_id" delete-volume --volume-id "$volume_id" || \
                    log_warn "Failed to delete volume $volume_id - may require manual cleanup"
            elif [[ "$volume_state" == "deleted" || "$volume_state" == "deleting" ]]; then
                log_info "Volume $volume_id is already deleted or being deleted"
            else
                log_warn "Volume $volume_id is in state '$volume_state' - cannot delete"
            fi
        done
    else
        log_info "No volumes to check"
    fi
    
    # Step 6: Cancel capacity reservation (if exists)
    log_step "6. Checking capacity reservation"
    if [[ -n "$capacity_reservation_id" ]]; then
        local reservation_info
        if ! reservation_info=$(aws_ec2 describe-capacity-reservations \
            --capacity-reservation-ids "$capacity_reservation_id" 2>/dev/null); then
            log_info "Capacity reservation $capacity_reservation_id not found or already cancelled"
        else
            local reservation_state
            reservation_state=$(echo "$reservation_info" | jq -r '.CapacityReservations[0].State')
            
            if [[ "$reservation_state" == "active" ]]; then
                run_aws_command "Cancelling capacity reservation: $capacity_reservation_id" \
                    cancel-capacity-reservation --capacity-reservation-id "$capacity_reservation_id" || \
                    log_warn "Failed to cancel capacity reservation - may require manual cleanup"
            else
                log_info "Capacity reservation is in state '$reservation_state' - no action needed"
            fi
        fi
    else
        log_info "No capacity reservation to check"
    fi
    
    log_step "Cleanup completed!"
    log_info "Summary:"
    log_info "  - Instance: $INSTANCE_ID (terminated)"
    [[ -n "$eni_ids" ]] && log_info "  - ENIs: processed"
    [[ -n "$volume_ids" ]] && log_info "  - Volumes: processed"
    [[ -n "$capacity_reservation_id" ]] && log_info "  - Capacity Reservation: processed"
}

# Run main function
main
