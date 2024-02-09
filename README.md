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
