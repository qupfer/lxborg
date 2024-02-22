#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT=$(realpath  "${BASH_SOURCE[0]}")
CUR_DIR=$PWD
cd "$SCRIPT_DIR"



main(){
    parse_command_line "$@"
    import_config_file
    check_and_export_config

    # help 
    if [ -n "${help:-""}" ]; then
        readmemd | tee README.md
    fi

    # list repo 
    if [ -n "${list:-""}" ]; then
        "$BORG_BIN_REAL" rlist
    fi

    # create tar from borg
    if [ -n "${extract:-""}" ]; then
        check_sudo "$@"
        create_importable_tar_from_borg
    fi

    # make abackup
    if [ -n "${backup:-""}" ]; then
        check_sudo "$@"
        backup
    fi

    # run borg
    if [ -n "${run:-""}" ]; then
        run
    fi
    exit 0

}

check_sudo(){
    uid=$(id -u)
    gid=$(id -g)

if [[ ${UID} -gt 0 ]] ; then
    uid=${cmd_uid:-$uid}
    gid=${cmd_gid:-$gid}
    sudo "$SCRIPT" "$@" --internal_uid "$uid" --internal_gid "$gid"
    exit 0
fi


}

check_and_export_config() {
    
    # use commandline options
    archivename=${cmd_archivename:-$archivename}
    snapshotname=${cmd_snapshotname:-$snapshotname}
    machinename=${cmd_machinename:-$machinename}

    #use system environment
    BORG_PASSPHRASE=${password:-$BORG_PASSPHRASE}
    BORG_REPO=${repo:-$BORG_REPO}

    BORG_REPO=$(realpath "$BORG_REPO")
    BORG_BIN_REAL=$(realpath "$BORG_BIN")
    export BORG_BIN_REAL
    export SNAPSHOT_PATH
    export BORG_PASSPHRASE
    export BORG_REPO
    [ -n "$BORG_REMOTE_PATH" ] && export BORG_REMOTE_PATH

}

import_config_file() {
    configfile=${configfile:-$SCRIPT_DIR/config.txt}
    if [ -f "$configfile" ]; then 
        # shellcheck source=config.txt
        source "$configfile"
    else 
        echo "Config file \"${configfile}\" does not exist."
        echo "An config.txt is created next to the $(basename "${BASH_SOURCE[0]}") script."
        echo "Please adapt it to your requirements."
        example_config > "$SCRIPT_DIR/config.txt"
        exit 0
    fi
}



parse_command_line(){
set -o errexit -o pipefail -o noclobber -o nounset

# shellcheck disable=SC2251
! getopt --test > /dev/null 
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo "I'm sorry, $(getopt --test) failed in this environment."
    exit 1
fi


LONGOPTS=run:,machinename:,snapshotname:,archivename:,configfile:,extract:,list,backup,password:,repo:,uid:,gid:,internal_uid:,internal_gid:,help
OPTIONS=r:m:s:a:c:x:,l,b,p:,h
# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly

# shellcheck disable=SC2251
! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    # e.g. return value is 1
    #  then getopt has complained about wrong arguments to stdout
    exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

while true; do
    case "$1" in
        -r|--run)
            #run=( "$2" )
            IFS=" " read -r -a run <<< "$2"
            shift 2
            ;;
        -m|--machinename)
            cmd_machinename="$2"
            shift 2
            ;;
        -s|--snapshotname)
            cmd_snapshotname="$2"
            shift 2
            ;;        
        -a|--archivename)
            cmd_archivename="$2"
            shift 2
            ;;
        -c|--configfile)
            configfile="${2}"
            shift 2
            ;;
        -p|--password)
            password="${2}"
            shift 2
            ;;
        -l|--list)
            list=True
            shift 1
            ;;
        -b|--backup)
            backup=True
            shift 1
            ;;
        -h|--help)
            help=True
            shift 1
            ;;
        -x|--extract)
            extract="$2"
            shift 2
            ;;
        --repo)
            repo="$2"
            shift 2
            ;;
        --uid)
            cmd_uid="$2"
            shift 2
            ;;
        --gid)
            cmd_gid="$2"
            shift 2
            ;;
        --internal_uid)
            internal_uid="$2"
            shift 2
            ;;
        --internal_gid)
            internal_gid="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Programming error"
            exit 3
            ;;
    esac
done
}



create_prefix(){
container_prefix=$(cat <<-EOF
name: $machinename
backend: btrfs
pool: default
optimized: false
optimized_header: false
type: container
config:
EOF
)

vm_prefix=$(cat <<-EOF
name: $machinename
backend: btrfs
pool: default
optimized: false
optimized_header: false
type: virtual-machine
config:
EOF
)
}

run(){
    "$BORG_BIN_REAL" "${run[@]}"
}



init_remote_borg(){
# put borg to destination
remote_sha=$(ssh -p "$ssh_port" "$ssh_user"@"${ssh_host}" "sha256sum $BORG_REMOTE_PATH" | cut -d" " -f1 || echo "")
local_sha=$(sha256sum "$BORG_BIN_REAL" | cut -d" " -f1)
[[ $remote_sha == "$local_sha" ]] || scp -P "$ssh_port" "$BORG_BIN_REAL" "$ssh_user"@"${ssh_host}":"$BORG_REMOTE_PATH"
}

backup(){
    init_borg_repo
    [ -z "$archivename" ] && archivename="${machinename}_$(date +%F_%T)"
    
    # make a snapsghot
    lxc snapshot "$machinename"  "$snapshotname" --reuse
    
    # container of vm?
    type=$(lxc info "$machinename" | grep -i '^Type:' | cut -d' ' -f2)
    [ "$type" == container ] && cd "$CONTAINER_SNAPSHOT_PATH/$machinename"
    [ "$type" == virtual-machine ] && cd "$VM_SNAPSHOT_PATH/$machinename"
    
    "$BORG_BIN_REAL" create  -s  --progress --compression zstd "$archivename" "$snapshotname"
    chown_repo
}

chown_repo() {
    # fix ownership
    #echo chown -R "$internal_uid:$internal_gid" "$BORG_REPO"
    chown -R "${internal_uid}:${internal_gid}" "$BORG_REPO"
}

init_borg_repo(){

    if grep -q "ssh:" <<< "$BORG_REPO"; then
        echo ssh 
        init_remote_borg
    fi
    # show current archives or create repo 
    "$BORG_BIN_REAL" rlist || "$BORG_BIN_REAL" rcreate --encryption=repokey-aes-ocb 
}


create_importable_tar_from_borg(){
    create_prefix
    tempdir=$(mktemp -d -p .)
    cd "$tempdir"
    
    # extract all
    "$BORG_BIN_REAL" extract "$extract"
    filepath="$CUR_DIR"/"$extract".tar
    

    #chmod -R u+rw *
    backup_yaml=$(realpath "$(find . -iname backup.yaml)")

    # remove snapshot related stuff
    sed -i -e '/^snapshots:/,/^[a-z]\+:/{/^[a-z]\+:/!d}' -e '/^volume_snapshots:/,/^[a-z]\+:/{/^[a-z]\+:/!d}' "$backup_yaml"

    # prepare index.yaml
    machinename=$(sed -n '/^container:$/,/^[a-z]*:/p'  "$backup_yaml" | grep -i "^  name: " | cut -d" " -f4)
    info=$(sudo sed 's/^/  /' "$backup_yaml")
    grep -sq "type: container" "$backup_yaml" && { prefix=$container_prefix; mv "$snapshotname" container; }
    grep -sq "type: virtual-machine" "$backup_yaml" && { prefix=$vm_prefix; mv "$snapshotname" virtual-machine ; mv virtual-machine/root.img virtual-machine.img; }
    printf "%s\n%s" "$prefix" "$info"  > "index.yaml"
    sed -i "s/^name:.*/name: $machinename/g" index.yaml

    # tar it
    cd ..
    dirname=$(basename "$tempdir")
    read -r -a additonal_tar_args_array <<< "$additonal_tar_args"
    tar "${additonal_tar_args_array[@]}" -c -f "$filepath"  --numeric-owner --xattrs --acls --transform "s#$dirname#backup#" "$dirname"
    chown "${internal_uid:-0}":"${internal_gid:-0}" "$filepath"
    suffix=$(file -b --extension "$filepath")
    mv "$filepath" "${filepath}.${suffix}"
    # clean up
    rm -rf "$tempdir"
    exit 0
}


readmemd() {
cat << 'EOF'
# lxborg
A script to make borg backups of lxd instances without writing the full archive on disk temporary


## Usage 

1. add & modify config.txt
2. execute ./lxborg.sh
3. overwrite config with commandline parameters
    - `-r | --run` for a borg command - `./lxborg.sh -r "rlist"` or `./lxborg.sh -r "rlist myContainer_2023-02-17_07:37:25`
    - `-m | --machinename` for the conteriner/vm name
    - `-a | --archivename` for a custom archive name (defaults to `machinename_$(date +%F_%T)`
    - `-s | --snapshotname` for the name of the source snapshot (defaults to `borg`)

4. create a backup
   - `./lxborg.sh -b`  (using parameters from config.txt or form the script itself)
   - `-/lxborg.sh -b -m c2` for overwriting the machinename to `c2`
   - [...]
5. restore a backup
   - get list: `./lxborg.sh -l`
   - extract:  `./lxborg.sh -x "myContainer_2023-02-17_07:37:25"`
   - import: `lxc import myContainer_2023-02-17_07:37:25.tar` 
EOF
}

example_config() {
cat << 'EOF'
#!/bin/bash
# shellcheck disable=SC2034

#### COPY TO CONFIGFILE ####
### Backup Config ###

# use "--machinename Machinename" (-m) option to overwrite
machinename=haproxy

# use "--snapshotname Snapshotname" (-s) option to overwrite
snapshotname=borg

# use "--archivename Archivename" (-a) option to overwrite
# if its empty, the archivename is name_date (machinename_2023-02-17_07:37:25)
archivename=""  

# maybe add verbose or compression to tar command
additonal_tar_args="-v --zstd"

### SSH Config ###
# only used in BORG_REPO
ssh_user=root
ssh_host=myhost.domain.com
ssh_port=22
ssh_borg_repo_path=/data/borg_repo
ssh_key="" # not implemented yet


### BORG CONFIG ###
# use "--repo /path/to/repo" option to overwrite or set it as an environment variable outside this config

# ssh repo
BORG_REPO="ssh://${ssh_user}"@"${ssh_host}":"${ssh_port}${ssh_borg_repo_path}"

# local repo
BORG_REPO=./lxborg_repo

# set the BORG variable 
BORG_BIN="./borg2b7"

# use "--password Password" (-p) option to overwrite or set it as an environment variable outside this config
BORG_PASSPHRASE="abcde"

# put borg to $HOME of remote host
BORG_REMOTE_PATH="\$HOME/borg_$HOSTNAME"

### LXC CONFIG ###
CONTAINER_SNAPSHOT_PATH="/var/snap/lxd/common/lxd/snapshots"
VM_SNAPSHOT_PATH="/var/snap/lxd/common/lxd/virtual-machines-snapshots"

### END COPY TO CONFIGFILE ###
EOF
}
main "$@"
