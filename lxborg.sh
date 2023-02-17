#!/bin/bash


### Backup Config ###
machinename=myContainer
snapshotname=borg
archivename=""   # if its empty, the archivename is name_date (myContainer_2023-02-17_07:37:25)

### SSH Config ###
ssh_user=root
ssh_host=myhost.domain.com
ssh_port=22
ssh_key="" # not implemented yet

### BORG CONFIG ###
borg_repo="ssh://${ssh_user}"@"${ssh_host}":"${ssh_port}/data/praxis_repo"
borg_bin="./borg2b4"
borg_passphrase="abcde"
borg_remote_path='~/borg_portable'

### LXC CONFIG ###
container_snapshot_path="/var/snap/lxd/common/lxd/snapshots"

### commandline options from https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# More safety, by turning some bugs into errors.
# Without `errexit` you don’t need ! and can replace
# ${PIPESTATUS[0]} with a simple $?, but I prefer safety.
set -o errexit -o pipefail -o noclobber -o nounset

# -allow a command to fail with !’s side effect on errexit
# -use return value from ${PIPESTATUS[0]}, because ! hosed $?
! getopt --test > /dev/null 
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo 'I’m sorry, `getopt --test` failed in this environment.'
    exit 1
fi

LONGOPTS=machinename:,snapshotname:,archivename:
OPTIONS=m:s:a:
# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    # e.g. return value is 1
    #  then getopt has complained about wrong arguments to stdout
    exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

machinename=$machinename snapshotname=$snapshotname archivename=$archivename

while true; do
    case "$1" in
        -m|--machinename)
            machinename="$2"
            shift 2
            ;;
        -s|--snapshotname)
            snapshotname="$2"
            shift 2
            ;;        
        -a|--archivename)
            archivename="$2"
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




### Backup Config ###
date=$(date +%F_%T)
 [ -z "$archivename" ] && archivename="${machinename}_$(date +%F_%T)"


### CODE ###
export BORG_REMOTE_PATH="$borg_remote_path"
export BORG_BIN="$borg_bin"
export BORG_REPO="$borg_repo"
export BORG_PASSPHRASE="$borg_passphrase"


# make a snapsghot
lxc snapshot "$container_name"  "$snapshotname" --reuse


# prepare index.yaml
container_prefix=$(cat <<-EOF
name: $container_name
backend: btrfs
pool: default
optimized: false
optimized_header: false
type: container
config:
EOF
)
container_info=$(sed 's/^/  /' "$container_snapshot_path/$container_name/$snapshotname/backup.yaml")
printf "${container_prefix}\n${container_info}" >  /tmp/index.yaml


# put borg to destination
remote_sha=$(ssh -p $ssh_port $ssh_user@${ssh_host} "sha256sum $BORG_REMOTE_PATH" | cut -d" " -f1)
local_sha=$(sha256sum "$BORG_BIN" | cut -d" " -f1)
[[ $remote_sha == $local_sha ]] || scp -P $ssh_port "$BORG_BIN" "$ssh_user"@"${ssh_host}:$BORG_REMOTE_PATH"


# show current archives or create repo 
"$BORG_BIN" rlist || "$BORG_BIN" rcreate --encryption=repokey-aes-ocb 


sudo tar --numeric-owner --xattrs --acls -c -O  -C "$container_snapshot_path/$container_name/"  --transform "s/$snapshotname/backup\/container/" "$snapshotname" -C /tmp --transform "s/^index.yaml/backup\/index.yaml/" index.yaml | \
"$BORG_BIN" create  -s --list --compression zstd --stdin-name "${archive_name}.tar" "$archive_name" -

