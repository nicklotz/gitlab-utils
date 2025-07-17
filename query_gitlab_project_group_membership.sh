# Checks for "active" vs "inactive" users on a GitLab instance using the following criteria:
# Active user = member of at least one project and/or one group
# Inactive user = not a member of any project nor group
# Script returns CSVs of active and inactive users, respectively

# Usage: HOST=<gitlab url> TOKEN=<gitlab pat> ./query_gitlab_project_group_membership.sh


#!/bin/bash

readonly GITLAB_URL="${HOST:-https://gitlab.example.com}"
readonly ACCESS_TOKEN="${TOKEN:-your_access_token_here}"
readonly ACTIVE_USERS_FILE="active_users.csv"
readonly INACTIVE_USERS_FILE="inactive_users.csv"
readonly API_PAGE_SIZE=100
readonly CSV_HEADER="id,username,name,email"

initialize_csv_files() {
    echo "$CSV_HEADER" > "$ACTIVE_USERS_FILE"
    echo "$CSV_HEADER" > "$INACTIVE_USERS_FILE"
}

fetch_users_page() {
    local page_number=$1
    curl -s --header "PRIVATE-TOKEN: $ACCESS_TOKEN" \
        "$GITLAB_URL/api/v4/users?per_page=$API_PAGE_SIZE&page=$page_number"
}

is_valid_json_array() {
    local json_response=$1
    echo "$json_response" | jq -e 'type == "array"' >/dev/null 2>&1
}

get_array_length() {
    local json_array=$1
    echo "$json_array" | jq length
}

extract_api_error_message() {
    local json_response=$1
    echo "$json_response" | jq -r '.message // .error // .'
}

fetch_user_memberships() {
    local user_id=$1
    curl -s --header "PRIVATE-TOKEN: $ACCESS_TOKEN" \
        "$GITLAB_URL/api/v4/users/$user_id/memberships"
}

count_memberships_by_type() {
    local memberships=$1
    local membership_type=$2
    echo "$memberships" | jq "[.[] | select(.source_type == \"$membership_type\")] | length" 2>/dev/null || echo "0"
}

is_membership_response_valid() {
    local memberships=$1
    [ -n "$memberships" ] && [ "$memberships" != "null" ]
}

extract_user_field() {
    local user_json=$1
    local field_name=$2
    echo "$user_json" | jq -r ".$field_name"
}

is_user_active() {
    local user_state=$1
    [ "$user_state" = "active" ]
}

has_any_membership() {
    local group_count=$1
    local project_count=$2
    (( group_count > 0 || project_count > 0 ))
}

format_csv_line() {
    local user_id=$1
    local username=$2
    local full_name=$3
    local email=$4
    echo "$user_id,$username,\"$full_name\",$email"
}

append_to_active_users() {
    local csv_line=$1
    echo "$csv_line" >> "$ACTIVE_USERS_FILE"
}

append_to_inactive_users() {
    local csv_line=$1
    echo "$csv_line" >> "$INACTIVE_USERS_FILE"
}

process_user() {
    local user_json=$1
    
    local user_id=$(extract_user_field "$user_json" "id")
    local username=$(extract_user_field "$user_json" "username")
    local full_name=$(extract_user_field "$user_json" "name")
    local email=$(extract_user_field "$user_json" "email")
    local user_state=$(extract_user_field "$user_json" "state")
    
    if ! is_user_active "$user_state"; then
        echo "Skipping blocked or non-active user $username"
        return
    fi
    
    local memberships=$(fetch_user_memberships "$user_id")
    local group_count=0
    local project_count=0
    
    if is_membership_response_valid "$memberships"; then
        group_count=$(count_memberships_by_type "$memberships" "Namespace")
        project_count=$(count_memberships_by_type "$memberships" "Project")
    else
        echo "Failed to fetch memberships for user $username (ID: $user_id)" >&2
    fi
    
    echo "User $username (ID: $user_id): Groups=$group_count, Projects=$project_count"
    
    local csv_line=$(format_csv_line "$user_id" "$username" "$full_name" "$email")
    
    if has_any_membership "$group_count" "$project_count"; then
        append_to_active_users "$csv_line"
    else
        append_to_inactive_users "$csv_line"
    fi
}

process_all_users() {
    local page_number=1
    
    while true; do
        echo "Fetching users page $page_number..."
        local users_response=$(fetch_users_page "$page_number")
        
        if is_valid_json_array "$users_response"; then
            local user_count=$(get_array_length "$users_response")
        else
            echo "API error on page $page_number: $(extract_api_error_message "$users_response")"
            user_count=0
        fi
        
        echo "Found $user_count users on page $page_number"
        
        if [ "$user_count" -eq 0 ]; then
            echo "No more users to process."
            break
        fi
        
        while IFS= read -r user; do
            process_user "$user"
        done < <(echo "$users_response" | jq -c '.[]')
        
        ((page_number++))
    done
}

get_line_count() {
    local file=$1
    wc -l < "$file"
}

extract_user_ids_from_csv() {
    local csv_file=$1
    tail -n +2 "$csv_file" | cut -d',' -f1 | sort
}

find_duplicate_user_ids() {
    local active_ids=$1
    local inactive_ids=$2
    comm -12 <(echo "$active_ids") <(echo "$inactive_ids")
}

check_for_duplicate_users() {
    echo -n "Checking for duplicate users: "
    local active_ids=$(extract_user_ids_from_csv "$ACTIVE_USERS_FILE")
    local inactive_ids=$(extract_user_ids_from_csv "$INACTIVE_USERS_FILE")
    local duplicates=$(find_duplicate_user_ids "$active_ids" "$inactive_ids")
    
    if [ -z "$duplicates" ]; then
        echo "✓ No users appear in both files"
    else
        echo "✗ WARNING: Found users in both files: $duplicates"
    fi
}

validate_csv_row() {
    local csv_file=$1
    local id=$2
    local username=$3
    local row_type=$4
    local errors=0
    
    if [ "$row_type" != "header" ]; then
        if [ -z "$id" ]; then
            echo "✗ ERROR: Empty ID found in $csv_file"
            ((errors++))
        fi
        if [ -z "$username" ]; then
            echo "✗ ERROR: Empty username found in $csv_file"
            ((errors++))
        fi
    fi
    
    echo "$errors"
}

verify_csv_data_integrity() {
    echo -n "Verifying data integrity: "
    local total_errors=0
    
    while IFS=',' read -r id username name email; do
        local row_type=$( [ "$id" = "id" ] && echo "header" || echo "data" )
        local errors=$(validate_csv_row "$ACTIVE_USERS_FILE" "$id" "$username" "$row_type")
        ((total_errors += errors))
    done < "$ACTIVE_USERS_FILE"
    
    while IFS=',' read -r id username name email; do
        local row_type=$( [ "$id" = "id" ] && echo "header" || echo "data" )
        local errors=$(validate_csv_row "$INACTIVE_USERS_FILE" "$id" "$username" "$row_type")
        ((total_errors += errors))
    done < "$INACTIVE_USERS_FILE"
    
    if [ $total_errors -eq 0 ]; then
        echo "✓ All required fields are present"
    else
        echo "✗ Found $total_errors integrity errors"
    fi
}

display_results() {
    echo "Done!"
    echo "Results:"
    echo "  $(get_line_count "$ACTIVE_USERS_FILE") lines in $ACTIVE_USERS_FILE"
    echo "  $(get_line_count "$INACTIVE_USERS_FILE") lines in $INACTIVE_USERS_FILE"
}

run_validation_checks() {
    echo ""
    echo "Running validation checks..."
    check_for_duplicate_users
    verify_csv_data_integrity
}

main() {
    echo "Starting user membership export from $GITLAB_URL"
    
    initialize_csv_files
    process_all_users
    display_results
    run_validation_checks
}

main "$@"
