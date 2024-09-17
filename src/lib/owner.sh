#!/bin/bash
# shellcheck disable=SC1091,SC2015

source lib/package.sh

request_owner() {
    check_limit || return $?
    [ -n "$1" ] || return
    local owner
    local id
    local return_code=0
    owner=$(_jq "$1" '.login')
    id=$(_jq "$1" '.id')
    while ! ln "$BKG_OWNERS" "$BKG_OWNERS.lock" 2>/dev/null; do :; done
    grep -q "^.*\/*$owner$" "$BKG_OWNERS" || echo "$id/$owner" >>"$BKG_OWNERS"

    if [ "$(stat -c %s "$BKG_OWNERS")" -ge 100000000 ]; then
        sed -i '$d' "$BKG_OWNERS"
        return_code=2
    else
        set_BKG BKG_LAST_SCANNED_ID "$id"
    fi

    rm -f "$BKG_OWNERS.lock"
    return $return_code
}

save_owner() {
    check_limit || return $?
    owner=$(echo "$1" | tr -d '[:space:]')
    [ -n "$owner" ] || return
    owner_id=""

    if [[ "$owner" =~ .*\/.* ]]; then
        owner_id=$(cut -d'/' -f1 <<<"$owner")
        owner=$(cut -d'/' -f2 <<<"$owner")
    fi

    if [[ ! "$owner_id" =~ ^[1-9] ]]; then
        owner_id=$(query_api "users/$owner")
        (($? != 3)) || return 3
        owner_id=$(jq -r '.id' <<<"$owner_id")
    fi

    ! set_BKG_set BKG_OWNERS_QUEUE "$owner_id/$owner" || echo "Queued $owner"
}

page_owner() {
    check_limit || return $?
    [ -n "$1" ] || return
    local owners_more="[]"

    if [ -n "$GITHUB_TOKEN" ]; then
        echo "Checking owners page $1..."
        owners_more=$(query_api "users?per_page=100&page=$1&since=$(get_BKG BKG_LAST_SCANNED_ID)")
        (($? != 3)) || return 3
    fi

    # if owners doesn't have .login, break
    jq -e '.[].login' <<<"$owners_more" &>/dev/null || return 2
    local owners_lines
    owners_lines=$(jq -r '.[] | @base64' <<<"$owners_more")
    run_parallel request_owner "$owners_lines"
    (($? != 3)) || return 3
    echo "Checked owners page $1"
    # if there are fewer than 100 lines, break
    [ "$(wc -l <<<"$owners_lines")" -eq 100 ] || return 2
}

update_owner() {
    check_limit || return $?
    [ -n "$1" ] || return
    owner=$(cut -d'/' -f2 <<<"$1")
    owner_id=$(cut -d'/' -f1 <<<"$1")
    # decode percent-encoded characters and make lowercase (eg. for docker manifest)
    # shellcheck disable=SC2034
    lower_owner=$(perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/eg' <<<"${owner//%/%25}" | tr '[:upper:]' '[:lower:]')
    echo "Updating $owner..."
    [ -n "$(curl "https://github.com/orgs/$owner/people" | grep -zoP 'href="/orgs/'"$owner"'/people"' | tr -d '\0')" ] && export owner_type="orgs" || export owner_type="users"

    if [ "$owner_type" = "users" ]; then
        for page in $(seq 1 100); do
            local user_orgs
            local user_orgs_lines
            user_orgs=$(query_api "$owner_type/$owner/orgs?per_page=100&page=$page")
            (($? != 3)) || return 3
            user_orgs_lines=$(jq -r '.[].login' <<<"$user_orgs" 2>/dev/null)
            run_parallel request_owner "$user_orgs_lines"
            (($? != 3)) || return 3
            [ "$(wc -l <<<"$user_orgs_lines")" -eq 100 ] || break
        done
    else
        for page in $(seq 1 100); do
            local org_members
            local org_members_lines
            org_members=$(query_api "$owner_type/$owner/public_members?per_page=100&page=$page")
            (($? != 3)) || return 3
            org_members_lines=$(jq -r '.[].login' <<<"$org_members" 2>/dev/null)
            run_parallel request_owner "$org_members_lines"
            (($? != 3)) || return 3
            [ "$(wc -l <<<"$org_members_lines")" -eq 100 ] || break
        done
    fi

    [ -d "$BKG_INDEX_DIR/$owner" ] || mkdir "$BKG_INDEX_DIR/$owner"
    set_BKG BKG_PACKAGES_"$owner" ""
    run_parallel save_package "$(sqlite3 "$BKG_INDEX_DB" "select package_type, package from '$BKG_INDEX_TBL_PKG' where owner_id = '$owner_id';" | awk -F'|' '{print "////"$1"//"$2}' | sort -uR)"

    for page in $(seq 1 100); do
        local pages_left=0
        local pkgs
        page_package "$page"
        pages_left=$?
        pkgs=$(get_BKG_set BKG_PACKAGES_"$owner")

        if [ -z "$pkgs" ]; then
            sed -i "/^.*\/*$owner$/d" "$BKG_OWNERS"
            return 2
        fi

        ((pages_left != 3)) || return 3
        run_parallel update_package "$pkgs"
        (($? != 3)) || return 3
        ((pages_left != 2)) || break
        set_BKG BKG_PACKAGES_"$owner" ""
    done

    echo "Updated $owner"
}
