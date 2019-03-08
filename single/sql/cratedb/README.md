Useful links:
https://hub.docker.com/_/crate/
https://github.com/crate/crate-python

Setup single-node cluster with:
https://crate.io/docs/crate/guide/en/latest/deployment/containers/docker.html#docker-compose

Must set vm.max_map_count=262144 or higher on docker host. Example sysctl command: 
`sudo sysctl -w vm.max_map_count=262144`
